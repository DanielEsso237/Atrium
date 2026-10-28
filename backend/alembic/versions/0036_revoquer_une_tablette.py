"""Une tablette se revoque a distance.

Une tablette perdue ou volee garde sa base : clients, ardoises, empreintes
des codes. Un responsable la revoque de l'ecran Tablettes ; a son prochain
contact avec le serveur, elle recoit un refus dedie (410) et efface sa base
et sa cle.

- `revoked_at`, `revoked_by`, `revocation_reason` : qui l'a revoquee, quand
  et pourquoi.

Revision ID: 0036_revoquer_une_tablette
Revises: 0035_abandon_a_distance
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0036_revoquer_une_tablette"
down_revision: Union[str, None] = "0035_abandon_a_distance"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "devices", sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.add_column("devices", sa.Column("revoked_by", sa.Uuid(), nullable=True))
    op.add_column("devices", sa.Column("revocation_reason", sa.Text(), nullable=True))
    op.create_foreign_key(
        op.f("fk_devices_revoked_by"),
        "devices",
        "users",
        ["revoked_by"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint(op.f("fk_devices_revoked_by"), "devices", type_="foreignkey")
    for colonne in ("revocation_reason", "revoked_by", "revoked_at"):
        op.drop_column("devices", colonne)
