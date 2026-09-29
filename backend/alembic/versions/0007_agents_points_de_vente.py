"""rattacher un agent a ses points de vente

- `user_outlets` : table de liaison (user_id, outlet_id), comme `user_roles`.
  Un agent sans aucune ligne voit tous les points de vente.

Revision ID: 0007_agents_points_de_vente
Revises: 0006_arrhes_en_caisse
Create Date: 2026-09-29
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0007_agents_points_de_vente"
down_revision: Union[str, None] = "0006_arrhes_en_caisse"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "user_outlets",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("outlet_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_user_outlets_user_id"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["outlet_id"],
            ["outlets.id"],
            name=op.f("fk_user_outlets_outlet_id"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("user_id", "outlet_id", name=op.f("pk_user_outlets")),
    )
    op.create_index(op.f("ix_user_outlets_outlet_id"), "user_outlets", ["outlet_id"])


def downgrade() -> None:
    op.drop_index(op.f("ix_user_outlets_outlet_id"), table_name="user_outlets")
    op.drop_table("user_outlets")
