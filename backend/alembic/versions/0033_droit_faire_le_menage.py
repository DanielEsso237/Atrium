"""Faire le menage devient un droit a part : `housekeeping.work`.

Un seul droit, `housekeeping.manage`, couvrait ouvrir, attribuer, commencer,
terminer, inspecter et revenir en arriere. La reception doit le porter -- le
depart d'un client ouvre une tache de menage -- et pouvait donc aussi
terminer un menage : une chambre declaree propre sans que personne n'y soit
passe.

Commencer, terminer et revenir en arriere passent a `housekeeping.work`.
`housekeeping.manage` garde ouvrir, attribuer et inspecter. Le nouveau droit
va a tous les roles qui avaient `housekeeping.manage`, sauf la reception :
l'administrateur, l'agent de menage, et tout role cree depuis par
l'administrateur, qui faisait le menage hier et doit pouvoir le faire demain.

Revision ID: 0033_droit_faire_le_menage
Revises: 0032_signaler_une_panne
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0033_droit_faire_le_menage"
down_revision: Union[str, None] = "0032_signaler_une_panne"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Le meme identifiant que `app/db/seed.py` et la tablette.
DROIT = uuid.UUID("01920000-0000-7000-8000-000000004147")
CODE = "housekeeping.work"
ANCIEN_LIBELLE = "Creer, assigner, executer une tache de nettoyage"
NOUVEAU_LIBELLE = "Ouvrir, attribuer, inspecter une tache de nettoyage"


def upgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            VALUES (:id, :code, 'Commencer, terminer ou corriger un menage', 'housekeeping')
            ON CONFLICT (code) DO NOTHING
            """
        ),
        {"id": DROIT, "code": CODE},
    )
    bind.execute(
        sa.text(
            """
            INSERT INTO role_permissions (role_id, permission_id)
            SELECT rp.role_id, travail.id
              FROM role_permissions rp
              JOIN permissions gestion ON gestion.id = rp.permission_id
              JOIN roles r ON r.id = rp.role_id
             CROSS JOIN permissions travail
             WHERE gestion.code = 'housekeeping.manage'
               AND travail.code = :code
               AND r.code <> 'RECEPTION'
               AND NOT EXISTS (
                     SELECT 1 FROM role_permissions deja
                      WHERE deja.role_id = rp.role_id AND deja.permission_id = travail.id)
            """
        ),
        {"code": CODE},
    )
    bind.execute(
        sa.text(
            "UPDATE permissions SET label = :nouveau "
            "WHERE code = 'housekeeping.manage' AND label = :ancien"
        ),
        {"ancien": ANCIEN_LIBELLE, "nouveau": NOUVEAU_LIBELLE},
    )


def downgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            "UPDATE permissions SET label = :ancien "
            "WHERE code = 'housekeeping.manage' AND label = :nouveau"
        ),
        {"ancien": ANCIEN_LIBELLE, "nouveau": NOUVEAU_LIBELLE},
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
