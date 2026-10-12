"""Les ardoises du comptoir : payer a la fin de sa consommation.

Au bar, un client prend une biere, puis un jus, et demande sa note en
partant (decision du 12 octobre). Jusqu'ici, le client de passage payait
chaque consommation sur-le-champ : l'ardoise naissait close.

- `folios.outlet_id` : le point de vente a qui appartient l'ardoise ;
- `folios.tab_number` : son numero au comptoir (« Passage n°3 ») ;
- `tab.cancel` : annuler l'ardoise d'un client parti sans payer, avec un
  motif. Un responsable : l'administrateur et le manager.

Revision ID: 0021_ardoises_du_comptoir
Revises: 0020_caisse_par_point_de_vente
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0021_ardoises_du_comptoir"
down_revision: Union[str, None] = "0020_caisse_par_point_de_vente"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Le meme identifiant que `app/db/seed.py`.
TAB_CANCEL = uuid.UUID("01920000-0000-7000-8000-000000004138")


def upgrade() -> None:
    op.add_column(
        "folios",
        sa.Column(
            "outlet_id",
            sa.Uuid(),
            sa.ForeignKey("outlets.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.create_index("ix_folios_outlet_id", "folios", ["outlet_id"])
    op.add_column("folios", sa.Column("tab_number", sa.Integer(), nullable=True))

    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            VALUES (:id, 'tab.cancel',
                    'Annuler l''ardoise d''un client parti sans payer', 'folio')
            ON CONFLICT (code) DO NOTHING
            """
        ),
        {"id": TAB_CANCEL},
    )
    for role in ("ADMIN", "MANAGER"):
        bind.execute(
            sa.text(
                """
                INSERT INTO role_permissions (role_id, permission_id)
                SELECT r.id, p.id FROM roles r, permissions p
                 WHERE r.code = :role AND p.code = 'tab.cancel'
                   AND NOT EXISTS (
                         SELECT 1 FROM role_permissions rp
                          WHERE rp.role_id = r.id AND rp.permission_id = p.id)
                """
            ),
            {"role": role},
        )


def downgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            DELETE FROM role_permissions
             WHERE permission_id IN (SELECT id FROM permissions WHERE code = 'tab.cancel')
            """
        )
    )
    bind.execute(sa.text("DELETE FROM permissions WHERE code = 'tab.cancel'"))
    op.drop_column("folios", "tab_number")
    op.drop_index("ix_folios_outlet_id", table_name="folios")
    op.drop_column("folios", "outlet_id")
