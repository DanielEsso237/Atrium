"""Les roles Econome, Controleur et Comptable, et qui fait quoi au stock.

Jusqu'ici l'administrateur tenait seul les stocks, « en attendant les
roles ». Les voici, avec trois droits qui separent les gestes :

- `stock.manage` : tenir l'economat -- entrees, sorties, ajustements.
  L'econome.
- `stock.transfer.request` : demander un transfert. L'econome, qui
  ravitaille, et les points de vente, qui se ravitaillent.
- `stock.transfer.approve` (deja la, 0014) : le controleur et le comptable.

`stock.movement` couvrait tout d'un bloc. La route ne le regarde plus : tout
role qui le portait recoit les deux nouveaux droits, pour qu'aucun agent ne
perde un geste qu'il faisait hier.

Revision ID: 0019_roles_du_stock
Revises: 0018_reception_caisse_centrale
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0019_roles_du_stock"
down_revision: Union[str, None] = "0018_reception_caisse_centrale"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Les memes identifiants que `app/db/seed.py`, pour que le seed retrouve les
# lignes au lieu d'en creer de secondes.
ROLES = (
    (uuid.UUID("01920000-0000-7000-8000-000000004008"), "ECONOME", "Econome"),
    (uuid.UUID("01920000-0000-7000-8000-000000004009"), "CONTROLEUR", "Controleur"),
    (uuid.UUID("01920000-0000-7000-8000-000000004010"), "COMPTABLE", "Comptable"),
)
PERMISSIONS = (
    (
        uuid.UUID("01920000-0000-7000-8000-000000004136"),
        "stock.manage",
        "Tenir l'economat : entrees, sorties et ajustements de stock",
    ),
    (
        uuid.UUID("01920000-0000-7000-8000-000000004137"),
        "stock.transfer.request",
        "Demander un transfert de stock",
    ),
)
NOUVEAUX_DROITS = tuple(code for _, code, _ in PERMISSIONS)

# Ce que chaque role recoit. Lire le stock va avec chacun des trois gestes :
# l'ecran Stocks s'ouvre sous stock.read.
DROITS = (
    ("ECONOME", "stock.read"),
    ("ECONOME", "stock.manage"),
    ("ECONOME", "stock.transfer.request"),
    ("RESTAURANT", "stock.transfer.request"),
    ("CONTROLEUR", "stock.read"),
    ("CONTROLEUR", "stock.transfer.approve"),
    ("COMPTABLE", "stock.read"),
    ("COMPTABLE", "stock.transfer.approve"),
)

_RATTACHER = """
    INSERT INTO role_permissions (role_id, permission_id)
    SELECT r.id, p.id FROM roles r, permissions p
     WHERE r.code = :role AND p.code = :code
       AND NOT EXISTS (
             SELECT 1 FROM role_permissions rp
              WHERE rp.role_id = r.id AND rp.permission_id = p.id)
"""


def upgrade() -> None:
    bind = op.get_bind()

    for role_id, code, label in ROLES:
        bind.execute(
            sa.text(
                """
                INSERT INTO roles (id, code, label, is_system)
                VALUES (:id, :code, :label, true)
                ON CONFLICT (code) DO NOTHING
                """
            ),
            {"id": role_id, "code": code, "label": label},
        )
    for perm_id, code, label in PERMISSIONS:
        bind.execute(
            sa.text(
                """
                INSERT INTO permissions (id, code, label, module)
                VALUES (:id, :code, :label, 'stock')
                ON CONFLICT (code) DO NOTHING
                """
            ),
            {"id": perm_id, "code": code, "label": label},
        )

    # L'administrateur a tout, et quiconque portait stock.movement garde ses
    # gestes -- un role ajuste a la main depuis l'administration compris.
    for code in NOUVEAUX_DROITS:
        bind.execute(sa.text(_RATTACHER), {"role": "ADMIN", "code": code})
        bind.execute(
            sa.text(
                """
                INSERT INTO role_permissions (role_id, permission_id)
                SELECT rp.role_id, p.id
                  FROM role_permissions rp
                  JOIN permissions ancien ON ancien.id = rp.permission_id
                  JOIN permissions p ON p.code = :code
                 WHERE ancien.code = 'stock.movement'
                   AND NOT EXISTS (
                         SELECT 1 FROM role_permissions deja
                          WHERE deja.role_id = rp.role_id AND deja.permission_id = p.id)
                """
            ),
            {"code": code},
        )
    for role, code in DROITS:
        bind.execute(sa.text(_RATTACHER), {"role": role, "code": code})


def downgrade() -> None:
    bind = op.get_bind()
    for code in NOUVEAUX_DROITS:
        bind.execute(
            sa.text(
                """
                DELETE FROM role_permissions rp USING permissions p
                 WHERE rp.permission_id = p.id AND p.code = :code
                """
            ),
            {"code": code},
        )
        bind.execute(sa.text("DELETE FROM permissions WHERE code = :code"), {"code": code})
    # Les rattachements (droits, agents) partent avec le role : leurs cles
    # etrangeres sont en cascade.
    for _, code, _ in ROLES:
        bind.execute(sa.text("DELETE FROM roles WHERE code = :code"), {"code": code})
