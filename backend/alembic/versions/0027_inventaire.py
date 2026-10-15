"""Les droits de l'inventaire : compter, et reequilibrer.

Les tables `inventories` et `inventory_lines` existent depuis le schema
initial ; il manquait les routes (ticket O4) et leurs droits :

- `stock.inventory` : ouvrir l'inventaire d'un magasin, compter, abandonner.
  L'administrateur, la direction, l'econome et le controleur ;
- `stock.rebalance` : aligner le stock sur le comptage -- un manque devient
  une perte, un surplus un ajustement. L'administrateur, la direction, le
  controleur et le comptable.

La direction recoit aussi `stock.read` : l'ecran Inventaire montre le stock
qu'elle compte.

Revision ID: 0027_inventaire
Revises: 0026_depenses
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0027_inventaire"
down_revision: Union[str, None] = "0026_depenses"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Les memes identifiants que `app/db/seed.py` et la tablette.
DROITS = [
    (
        uuid.UUID("01920000-0000-7000-8000-000000004141"),
        "stock.inventory",
        "Faire l'inventaire d'un magasin",
        ("ADMIN", "MANAGER", "ECONOME", "CONTROLEUR"),
    ),
    (
        uuid.UUID("01920000-0000-7000-8000-000000004142"),
        "stock.rebalance",
        "Reequilibrer le stock apres inventaire",
        ("ADMIN", "MANAGER", "CONTROLEUR", "COMPTABLE"),
    ),
]

_ACCORDER = sa.text(
    """
    INSERT INTO role_permissions (role_id, permission_id)
    SELECT r.id, p.id FROM roles r, permissions p
     WHERE r.code = :role AND p.code = :code
       AND NOT EXISTS (
             SELECT 1 FROM role_permissions rp
              WHERE rp.role_id = r.id AND rp.permission_id = p.id)
    """
)


def upgrade() -> None:
    bind = op.get_bind()
    for id_, code, libelle, roles in DROITS:
        bind.execute(
            sa.text(
                """
                INSERT INTO permissions (id, code, label, module)
                VALUES (:id, :code, :label, 'stock')
                ON CONFLICT (code) DO NOTHING
                """
            ),
            {"id": id_, "code": code, "label": libelle},
        )
        for role in roles:
            bind.execute(_ACCORDER, {"role": role, "code": code})
    bind.execute(_ACCORDER, {"role": "MANAGER", "code": "stock.read"})


def downgrade() -> None:
    bind = op.get_bind()
    for _, code, _, _ in DROITS:
        bind.execute(
            sa.text(
                """
                DELETE FROM role_permissions
                 WHERE permission_id IN (SELECT id FROM permissions WHERE code = :code)
                """
            ),
            {"code": code},
        )
        bind.execute(sa.text("DELETE FROM permissions WHERE code = :code"), {"code": code})
    # `stock.read` de la direction reste : on ne sait pas s'il lui avait ete
    # donne a la main avant cette migration.
