"""La commande en chambre : la reception commande, le point de vente livre.

Le client appelle la reception depuis sa chambre ; elle commande pour lui au
point de vente, qui prend la commande en charge et la monte. A la livraison,
les lignes passent sur l'ardoise du sejour (F2.6, reunion du 18 octobre).

La table `orders` existait deja ; il lui manquait de dire qui a fait quoi,
la commande passant par deux metiers :

- `ordered_by` : la reception qui a commande ;
- `taken_by`, `taken_at` : l'agent du point de vente qui l'a prise en charge ;
- `delivered_by` : celui qui l'a livree (`served_at` en garde l'instant) ;
- `cancelled_by` : celui qui l'a annulee (`cancel_reason` en garde le motif) ;
- `override_by` : le responsable qui a laisse passer la commande au-dela du
  plafond du client.

Et un droit, `room_order.create` : commander pour une chambre. La reception
et l'administrateur.

Revision ID: 0029_commande_en_chambre
Revises: 0028_annulations
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0029_commande_en_chambre"
down_revision: Union[str, None] = "0028_annulations"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Le meme identifiant que `app/db/seed.py` et la tablette.
DROIT = uuid.UUID("01920000-0000-7000-8000-000000004144")
CODE = "room_order.create"
ROLES = ("ADMIN", "RECEPTION")

AGENTS = ("ordered_by", "taken_by", "delivered_by", "cancelled_by", "override_by")


def upgrade() -> None:
    for colonne in AGENTS:
        op.add_column(
            "orders",
            sa.Column(
                colonne,
                sa.Uuid(),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
                nullable=True,
            ),
        )
    op.add_column("orders", sa.Column("taken_at", sa.DateTime(timezone=True), nullable=True))

    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            VALUES (:id, :code, 'Commander pour une chambre (room service)', 'order')
            ON CONFLICT (code) DO NOTHING
            """
        ),
        {"id": DROIT, "code": CODE},
    )
    for role in ROLES:
        bind.execute(
            sa.text(
                """
                INSERT INTO role_permissions (role_id, permission_id)
                SELECT r.id, p.id FROM roles r, permissions p
                 WHERE r.code = :role AND p.code = :code
                   AND NOT EXISTS (
                         SELECT 1 FROM role_permissions rp
                          WHERE rp.role_id = r.id AND rp.permission_id = p.id)
                """
            ),
            {"role": role, "code": CODE},
        )


def downgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            DELETE FROM role_permissions
             WHERE permission_id IN (SELECT id FROM permissions WHERE code = :code)
            """
        ),
        {"code": CODE},
    )
    bind.execute(sa.text("DELETE FROM permissions WHERE code = :code"), {"code": CODE})
    op.drop_column("orders", "taken_at")
    for colonne in reversed(AGENTS):
        op.drop_column("orders", colonne)
