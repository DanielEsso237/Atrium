"""le role RESTAURANT s'appelle desormais « Commandes »

Seul le libelle change : le code RESTAURANT reste le meme, les tablettes
reconnaissent un role par son code.

Revision ID: 0010_role_commandes
Revises: 0009_commandes_folio_charge
Create Date: 2026-10-03
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0010_role_commandes"
down_revision: Union[str, None] = "0009_commandes_folio_charge"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("UPDATE roles SET label = 'Commandes' WHERE code = 'RESTAURANT'")


def downgrade() -> None:
    op.execute("UPDATE roles SET label = 'Restauration' WHERE code = 'RESTAURANT'")