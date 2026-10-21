"""Code oublie : un responsable le reinitialise sur place.

Un agent qui a oublie son PIN ou son mot de passe va chercher un
responsable ; celui-ci tape son propre code sur la tablette, et l'agent en
choisit un nouveau. Ca marche hors ligne, et le serveur reverifie a la
remontee (`POST /auth/reset-secret`).

- `users.reset_secret` : autoriser la reinitialisation du code d'un agent.
  L'administrateur et la direction, comme `operations.undo`.

Pas de colonne : `failed_login_count` et `locked_until` existent deja. Ce
qui change, c'est leur lecture (`app/services/verrouillage.py`) : cinq
codes faux bloquent un agent jusqu'a ce qu'un responsable le debloque.

Revision ID: 0030_reinitialisation_code
Revises: 0029_commande_en_chambre
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0030_reinitialisation_code"
down_revision: Union[str, None] = "0029_commande_en_chambre"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Le meme identifiant que `app/db/seed.py` et la tablette.
DROIT = uuid.UUID("01920000-0000-7000-8000-000000004145")
CODE = "users.reset_secret"
ROLES = ("ADMIN", "MANAGER")


def upgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            VALUES (:id, :code, 'Reinitialiser le code oublie d''un agent', 'users')
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
