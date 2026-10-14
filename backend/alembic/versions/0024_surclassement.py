"""Le surclassement : une chambre d'une autre categorie que celle reservee.

A l'arrivee, le client recoit une chambre d'une categorie superieure
(demande du 14 octobre). Par defaut il garde le tarif reserve ; au cas par
cas, le tarif de la nouvelle categorie s'applique. La ligne change de
categorie -- la disponibilite se compte la ou le client dort -- et garde :

- `reservation_rooms.booked_room_type_id` : la categorie reservee ;
- `reservation_rooms.upgrade_reason` : le motif ;
- `reservation_rooms.upgraded_by` : qui l'a decide.

Revision ID: 0024_surclassement
Revises: 0023_nom_ardoise_comptoir
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0024_surclassement"
down_revision: Union[str, None] = "0023_nom_ardoise_comptoir"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "reservation_rooms",
        sa.Column(
            "booked_room_type_id",
            sa.Uuid(),
            sa.ForeignKey("room_types.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.add_column(
        "reservation_rooms", sa.Column("upgrade_reason", sa.String(length=255), nullable=True)
    )
    op.add_column(
        "reservation_rooms",
        sa.Column(
            "upgraded_by",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )


def downgrade() -> None:
    op.drop_column("reservation_rooms", "upgraded_by")
    op.drop_column("reservation_rooms", "upgrade_reason")
    op.drop_column("reservation_rooms", "booked_room_type_id")
