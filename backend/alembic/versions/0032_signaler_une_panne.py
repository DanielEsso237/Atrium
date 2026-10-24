"""La reception signale une panne ; les metiers du menage et de la maintenance
changent de nom.

Retours du 23 octobre :

- « Donner la possibilite de signaler une maintenance a la reception ».
  Nouveau droit `maintenance.report` : ouvrir un ticket, et rien d'autre. La
  reception le recoit, avec `maintenance.read` pour suivre ce qu'elle a
  signale. Prendre en charge, resoudre et clore restent a
  `maintenance.manage` : le technicien, pas le comptoir.
- « Remplacer les noms housekeeping et maintenance par des noms
  appropries » : « Agent de menage » et « Agent de maintenance ». Seulement si
  l'administrateur ne les a pas deja renommes lui-meme.

Revision ID: 0032_signaler_une_panne
Revises: 0031_journal_par_transaction
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0032_signaler_une_panne"
down_revision: Union[str, None] = "0031_journal_par_transaction"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Le meme identifiant que `app/db/seed.py` et la tablette.
DROIT = uuid.UUID("01920000-0000-7000-8000-000000004146")
CODE = "maintenance.report"
# (role, droit) : l'administrateur a tous les droits ; la reception signale
# et suit.
ATTRIBUTIONS = [
    ("ADMIN", CODE),
    ("RECEPTION", CODE),
    ("RECEPTION", "maintenance.read"),
]
# (code du role, ancien libelle, nouveau libelle)
LIBELLES = [
    ("HOUSEKEEPING", "Housekeeping", "Agent de ménage"),
    ("MAINTENANCE", "Maintenance", "Agent de maintenance"),
]


def upgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            VALUES (:id, :code, 'Signaler une panne (ouvrir un ticket)', 'maintenance')
            ON CONFLICT (code) DO NOTHING
            """
        ),
        {"id": DROIT, "code": CODE},
    )
    for role, code in ATTRIBUTIONS:
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
            {"role": role, "code": code},
        )
    for code, ancien, nouveau in LIBELLES:
        bind.execute(
            sa.text("UPDATE roles SET label = :nouveau WHERE code = :code AND label = :ancien"),
            {"code": code, "ancien": ancien, "nouveau": nouveau},
        )


def downgrade() -> None:
    bind = op.get_bind()
    for code, ancien, nouveau in LIBELLES:
        bind.execute(
            sa.text("UPDATE roles SET label = :ancien WHERE code = :code AND label = :nouveau"),
            {"code": code, "ancien": ancien, "nouveau": nouveau},
        )
    # La lecture de la maintenance par la reception part avec le droit qu'elle
    # accompagnait.
    bind.execute(
        sa.text(
            """
            DELETE FROM role_permissions
             WHERE role_id IN (SELECT id FROM roles WHERE code = 'RECEPTION')
               AND permission_id IN (SELECT id FROM permissions WHERE code = 'maintenance.read')
            """
        )
    )
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
