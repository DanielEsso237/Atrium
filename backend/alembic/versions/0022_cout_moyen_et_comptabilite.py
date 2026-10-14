"""Le cout moyen pondere des produits, et le droit de lire les marges.

Les produits avaient un prix d'achat et un prix de vente, saisis a la main.
Pour en tirer les marges et la valeur du stock, il faut ce que le stock a
reellement coute :

- `products.average_cost` : le cout moyen pondere, recalcule a chaque entree
  en stock qui dit son prix. Zero tant qu'aucune ne l'a fait : le cout du
  produit est alors son prix d'achat, et aucun produit existant n'a besoin
  d'etre repris ;
- `accounting.read` : lire les marges et la valeur du stock. L'administrateur,
  la direction, le controleur et le comptable. Pas le comptoir, qui compte son
  tiroir a l'aveugle.

Revision ID: 0022_cout_moyen_et_comptabilite
Revises: 0021_ardoises_du_comptoir
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0022_cout_moyen_et_comptabilite"
down_revision: Union[str, None] = "0021_ardoises_du_comptoir"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Le meme identifiant que `app/db/seed.py`.
ACCOUNTING_READ = uuid.UUID("01920000-0000-7000-8000-000000004139")


def upgrade() -> None:
    op.add_column(
        "products",
        sa.Column("average_cost", sa.BigInteger(), nullable=False, server_default="0"),
    )

    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            VALUES (:id, 'accounting.read',
                    'Lire les marges et la valeur du stock', 'accounting')
            ON CONFLICT (code) DO NOTHING
            """
        ),
        {"id": ACCOUNTING_READ},
    )
    for role in ("ADMIN", "MANAGER", "CONTROLEUR", "COMPTABLE"):
        bind.execute(
            sa.text(
                """
                INSERT INTO role_permissions (role_id, permission_id)
                SELECT r.id, p.id FROM roles r, permissions p
                 WHERE r.code = :role AND p.code = 'accounting.read'
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
             WHERE permission_id IN (SELECT id FROM permissions WHERE code = 'accounting.read')
            """
        )
    )
    bind.execute(sa.text("DELETE FROM permissions WHERE code = 'accounting.read'"))
    op.drop_column("products", "average_cost")
