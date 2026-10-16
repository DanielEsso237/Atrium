"""Revenir en arriere : annuler une arrivee, un depart, un encaissement.

Une erreur de saisie au comptoir se corrige, mais pas par celui qui l'a
faite : un responsable donne son code, meme quand c'est lui qui est connecte.

- `operations.undo` : autoriser une annulation. L'administrateur et la
  direction ;
- `payments.reverses_payment_id` : l'encaissement qu'une contre-ecriture
  annule. Un encaissement ne se supprime pas -- l'argent est sorti du tiroir
  et doit s'y voir --, il s'annule par un remboursement du meme montant, et
  une seule fois (index unique).

Revision ID: 0028_annulations
Revises: 0027_inventaire
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0028_annulations"
down_revision: Union[str, None] = "0027_inventaire"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Le meme identifiant que `app/db/seed.py` et la tablette.
DROIT = uuid.UUID("01920000-0000-7000-8000-000000004143")
CODE = "operations.undo"
ROLES = ("ADMIN", "MANAGER")


def upgrade() -> None:
    op.add_column(
        "payments",
        sa.Column(
            "reverses_payment_id",
            sa.Uuid(),
            sa.ForeignKey("payments.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.create_index(
        "uq_payments_reverses",
        "payments",
        ["reverses_payment_id"],
        unique=True,
        postgresql_where=sa.text("reverses_payment_id IS NOT NULL AND deleted_at IS NULL"),
    )

    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            VALUES (:id, :code, 'Autoriser une annulation (arrivee, depart, encaissement)',
                    'operations')
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
    op.drop_index("uq_payments_reverses", table_name="payments")
    op.drop_column("payments", "reverses_payment_id")
