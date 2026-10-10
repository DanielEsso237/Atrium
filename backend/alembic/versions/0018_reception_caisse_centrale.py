"""La reception est la caisse centrale, et aussi un point de vente.

Decision du 8 octobre : chaque soir, la recette de chaque point de vente,
ventes de passage comprises, est versee a la reception.

Schema : une caisse porte le point de vente dont elle est le tiroir
(`cash_sessions.outlet_id`, nul pour la caisse centrale) et ce que la
reception a confirme avoir recu (`received_*`). La fermeture d'une caisse de
point de vente est son versement : pas de table a part, c'est le meme geste.

Donnees : chaque hotel recoit un point de vente RECEPTION, la permission
`cash.central` existe et la reception la porte, avec de quoi vendre a son
comptoir (restaurant.read, order.read, order.create, folio.charge).

Revision ID: 0018_reception_caisse_centrale
Revises: 0017_pdv_lisent_le_stock
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

from app.core.ids import uuid7

revision: str = "0018_reception_caisse_centrale"
down_revision: Union[str, None] = "0017_pdv_lisent_le_stock"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

CODE = "RECEPTION"

# Les memes identifiants que `app/db/seed.py`, pour que le seed retrouve les
# lignes au lieu d'en creer de secondes.
DEMO_HOTEL = uuid.UUID("01920000-0000-7000-8000-000000000001")
DEMO_RECEPTION_OUTLET = uuid.UUID("01920000-0000-7000-8000-000000007002")
CASH_CENTRAL = uuid.UUID("01920000-0000-7000-8000-000000004135")

# Ce que la reception recoit en plus : la caisse centrale, et la vente a son
# comptoir.
DROITS_RECEPTION = (
    "cash.central",
    "restaurant.read",
    "order.read",
    "order.create",
    "folio.charge",
)


def upgrade() -> None:
    op.add_column(
        "cash_sessions",
        sa.Column("outlet_id", sa.Uuid(), nullable=True),
    )
    op.add_column("cash_sessions", sa.Column("received_amount", sa.BigInteger(), nullable=True))
    op.add_column("cash_sessions", sa.Column("received_by", sa.Uuid(), nullable=True))
    op.add_column(
        "cash_sessions", sa.Column("received_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.add_column("cash_sessions", sa.Column("received_session_id", sa.Uuid(), nullable=True))
    op.create_index("ix_cash_sessions_outlet_id", "cash_sessions", ["outlet_id"])
    op.create_index(
        "ix_cash_sessions_received_session_id", "cash_sessions", ["received_session_id"]
    )
    op.create_foreign_key(
        "fk_cash_sessions_outlet_id",
        "cash_sessions",
        "outlets",
        ["outlet_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_foreign_key(
        "fk_cash_sessions_received_by",
        "cash_sessions",
        "users",
        ["received_by"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_foreign_key(
        "fk_cash_sessions_received_session_id",
        "cash_sessions",
        "cash_sessions",
        ["received_session_id"],
        ["id"],
        ondelete="SET NULL",
    )

    bind = op.get_bind()

    # Le point de vente Reception de chaque hotel, s'il n'en a pas deja un
    # (la contrainte d'unicite (hotel_id, code) compte aussi les supprimes).
    hotels = sa.table("hotels", sa.column("id", sa.Uuid()))
    outlets = sa.table(
        "outlets",
        sa.column("id", sa.Uuid()),
        sa.column("hotel_id", sa.Uuid()),
        sa.column("code", sa.String()),
        sa.column("label", sa.String()),
        sa.column("allows_room_charge", sa.Boolean()),
        sa.column("sort_order", sa.Integer()),
    )
    hotel_ids = list(bind.execute(sa.select(hotels.c.id)).scalars())
    deja = set(bind.execute(sa.select(outlets.c.hotel_id).where(outlets.c.code == CODE)).scalars())
    rows = [
        {
            "id": DEMO_RECEPTION_OUTLET if hotel_id == DEMO_HOTEL else uuid7(),
            "hotel_id": hotel_id,
            "code": CODE,
            "label": "Réception",
            "allows_room_charge": True,
            "sort_order": 0,
        }
        for hotel_id in hotel_ids
        if hotel_id not in deja
    ]
    if rows:
        op.bulk_insert(outlets, rows)
    # Son magasin : une vente doit avoir d'ou sortir. Meme regle que
    # `ensure_outlet_location` : un magasin libre de meme code lui est
    # rattache plutot que doublonne.
    locations = sa.table(
        "stock_locations",
        sa.column("id", sa.Uuid()),
        sa.column("hotel_id", sa.Uuid()),
        sa.column("code", sa.String()),
        sa.column("label", sa.String()),
        sa.column("sort_order", sa.Integer()),
        sa.column("outlet_id", sa.Uuid()),
        sa.column("is_central", sa.Boolean()),
    )
    for outlet_id, hotel_id, label, sort_order in bind.execute(
        sa.text(
            "SELECT o.id, o.hotel_id, o.label, o.sort_order FROM outlets o "
            "WHERE o.code = :code AND NOT EXISTS "
            "(SELECT 1 FROM stock_locations l WHERE l.outlet_id = o.id)"
        ),
        {"code": CODE},
    ).all():
        libre = bind.execute(
            sa.select(locations.c.id).where(
                locations.c.hotel_id == hotel_id,
                locations.c.code == CODE,
                locations.c.outlet_id.is_(None),
                locations.c.is_central.is_(False),
            )
        ).scalar()
        if libre is not None:
            bind.execute(
                locations.update().where(locations.c.id == libre).values(outlet_id=outlet_id)
            )
        else:
            bind.execute(
                locations.insert().values(
                    id=uuid7(), hotel_id=hotel_id, code=CODE, label=label,
                    sort_order=(sort_order or 0) + 1, outlet_id=outlet_id, is_central=False,
                )
            )

    # La permission, puis les droits de la reception.
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            SELECT :id, 'cash.central',
                   'Tenir la caisse centrale : recevoir les versements des points de vente',
                   'cash'
             WHERE NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'cash.central')
            """
        ),
        {"id": CASH_CENTRAL},
    )
    # L'administrateur a tout, la nouvelle permission comprise.
    op.execute(
        """
        INSERT INTO role_permissions (role_id, permission_id)
        SELECT r.id, p.id FROM roles r, permissions p
         WHERE r.code = 'ADMIN' AND p.code = 'cash.central'
           AND NOT EXISTS (
                 SELECT 1 FROM role_permissions rp
                  WHERE rp.role_id = r.id AND rp.permission_id = p.id)
        """
    )
    for code in DROITS_RECEPTION:
        bind.execute(
            sa.text(
                """
                INSERT INTO role_permissions (role_id, permission_id)
                SELECT r.id, p.id FROM roles r, permissions p
                 WHERE r.code = 'RECEPTION' AND p.code = :code
                   AND NOT EXISTS (
                         SELECT 1 FROM role_permissions rp
                          WHERE rp.role_id = r.id AND rp.permission_id = p.id)
                """
            ),
            {"code": code},
        )


def downgrade() -> None:
    bind = op.get_bind()
    for code in DROITS_RECEPTION:
        bind.execute(
            sa.text(
                """
                DELETE FROM role_permissions rp USING roles r, permissions p
                 WHERE rp.role_id = r.id AND rp.permission_id = p.id
                   AND r.code = 'RECEPTION' AND p.code = :code
                """
            ),
            {"code": code},
        )
    op.execute(
        """
        DELETE FROM role_permissions rp USING permissions p
         WHERE rp.permission_id = p.id AND p.code = 'cash.central'
        """
    )
    op.execute("DELETE FROM permissions WHERE code = 'cash.central'")
    # Le point de vente Reception reste : il a pu vendre depuis, et un point
    # de vente ne se supprime jamais (voir l'API).
    op.drop_constraint(
        "fk_cash_sessions_received_session_id", "cash_sessions", type_="foreignkey"
    )
    op.drop_constraint("fk_cash_sessions_received_by", "cash_sessions", type_="foreignkey")
    op.drop_constraint("fk_cash_sessions_outlet_id", "cash_sessions", type_="foreignkey")
    op.drop_index("ix_cash_sessions_received_session_id", table_name="cash_sessions")
    op.drop_index("ix_cash_sessions_outlet_id", table_name="cash_sessions")
    op.drop_column("cash_sessions", "received_session_id")
    op.drop_column("cash_sessions", "received_at")
    op.drop_column("cash_sessions", "received_by")
    op.drop_column("cash_sessions", "received_amount")
    op.drop_column("cash_sessions", "outlet_id")
