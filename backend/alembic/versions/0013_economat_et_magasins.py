"""L'economat, et un magasin par point de vente.

Retours du 7 octobre : l'economat est le stock principal, qui ravitaille les
points de vente ; les points de vente se ravitaillent aussi entre eux. Chaque
point de vente a donc son magasin, et chaque hotel un economat.

Schema : `stock_locations.outlet_id` (un magasin par point de vente) et
`is_central` (un seul economat par hotel). Donnees : chaque hotel recoit son
economat et chaque point de vente son magasin. Un magasin deja nomme
ECONOMAT, ou portant le code d'un point de vente, est repris plutot que
doublonne.

Revision ID: 0013_economat_et_magasins
Revises: 0012_role_points_de_vente
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

from app.core.ids import uuid7

revision: str = "0013_economat_et_magasins"
down_revision: Union[str, None] = "0012_role_points_de_vente"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

ECONOMAT = "ECONOMAT"


def upgrade() -> None:
    op.add_column("stock_locations", sa.Column("outlet_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_stock_locations_outlet_id", "stock_locations", "outlets",
        ["outlet_id"], ["id"], ondelete="RESTRICT",
    )
    op.add_column(
        "stock_locations",
        sa.Column("is_central", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_unique_constraint("uq_stock_locations_outlet_id", "stock_locations", ["outlet_id"])
    op.create_index(
        "ux_stock_locations_central",
        "stock_locations",
        ["hotel_id"],
        unique=True,
        postgresql_where=sa.text("is_central"),
    )

    bind = op.get_bind()
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

    # L'economat de chaque hotel.
    for (hotel_id,) in bind.execute(sa.text("SELECT id FROM hotels")):
        existant = bind.execute(
            sa.select(locations.c.id).where(
                locations.c.hotel_id == hotel_id, locations.c.code == ECONOMAT
            )
        ).scalar()
        if existant is not None:
            bind.execute(
                locations.update().where(locations.c.id == existant).values(is_central=True)
            )
        else:
            bind.execute(
                locations.insert().values(
                    id=uuid7(), hotel_id=hotel_id, code=ECONOMAT, label="Économat",
                    sort_order=0, is_central=True,
                )
            )

    # Le magasin de chaque point de vente.
    for outlet_id, hotel_id, code, label, sort_order in bind.execute(
        sa.text("SELECT id, hotel_id, code, label, sort_order FROM outlets")
    ):
        libre = bind.execute(
            sa.select(locations.c.id).where(
                locations.c.hotel_id == hotel_id,
                locations.c.code == code,
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
                    id=uuid7(), hotel_id=hotel_id, code=code, label=label,
                    sort_order=(sort_order or 0) + 1, outlet_id=outlet_id, is_central=False,
                )
            )


def downgrade() -> None:
    # Les magasins crees restent : ils ont pu recevoir des mouvements.
    op.drop_index("ux_stock_locations_central", table_name="stock_locations")
    op.drop_constraint("uq_stock_locations_outlet_id", "stock_locations", type_="unique")
    op.drop_constraint("fk_stock_locations_outlet_id", "stock_locations", type_="foreignkey")
    op.drop_column("stock_locations", "is_central")
    op.drop_column("stock_locations", "outlet_id")
