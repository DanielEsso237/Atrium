"""seuil de consommation du client et trace de son depassement

- `guests.credit_limit` : seuil de consommation par client, 0 = pas de
  limite (valeur de toutes les fiches existantes). Jusqu'ici seul
  `companies.credit_limit` existait, qui borne le credit en compte d'une
  societe -- une autre decision.
- `folio_items.override_by` : le responsable qui a laisse une charge
  depasser ce seuil. Nul pour toutes les charges existantes.

Revision ID: 0005_seuil_consommation
Revises: 0004_numbering_integrity
Create Date: 2026-09-28
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0005_seuil_consommation"
down_revision: Union[str, None] = "0004_numbering_integrity"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "guests",
        sa.Column("credit_limit", sa.BigInteger(), nullable=False, server_default="0"),
    )
    op.add_column("folio_items", sa.Column("override_by", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        op.f("fk_folio_items_override_by"),
        "folio_items",
        "users",
        ["override_by"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint(op.f("fk_folio_items_override_by"), "folio_items", type_="foreignkey")
    op.drop_column("folio_items", "override_by")
    op.drop_column("guests", "credit_limit")
