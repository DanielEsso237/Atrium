"""Une ecriture refusee s'abandonne d'un autre poste.

Une file bloquee se voyait d'ailleurs (0034), mais rien ne la debloquait :
seul un encaissement se retirait, et seulement sur la tablette elle-meme.
Un responsable decide maintenant de l'ecran Tablettes, et la tablette
bloquee applique la decision a son prochain passage.

- `abandonable`, `abandon_note` : ce que la tablette bloquee dit de son
  ecriture. C'est elle qui sait ce qui en depend ; le serveur ne fait que
  relayer.
- `decision`, `decision_reason`, `decided_by`, `decided_at` : la decision
  du responsable, avec son motif.

Revision ID: 0035_abandon_a_distance
Revises: 0034_file_bloquee_a_distance
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0035_abandon_a_distance"
down_revision: Union[str, None] = "0034_file_bloquee_a_distance"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "sync_blocks",
        sa.Column("abandonable", sa.Boolean(), server_default=sa.false(), nullable=False),
    )
    op.add_column("sync_blocks", sa.Column("abandon_note", sa.Text(), nullable=True))
    op.add_column("sync_blocks", sa.Column("decision", sa.String(length=16), nullable=True))
    op.add_column("sync_blocks", sa.Column("decision_reason", sa.Text(), nullable=True))
    op.add_column("sync_blocks", sa.Column("decided_by", sa.Uuid(), nullable=True))
    op.add_column(
        "sync_blocks", sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.create_foreign_key(
        op.f("fk_sync_blocks_decided_by"),
        "sync_blocks",
        "users",
        ["decided_by"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint(op.f("fk_sync_blocks_decided_by"), "sync_blocks", type_="foreignkey")
    for colonne in (
        "decided_at",
        "decided_by",
        "decision_reason",
        "decision",
        "abandon_note",
        "abandonable",
    ):
        op.drop_column("sync_blocks", colonne)
