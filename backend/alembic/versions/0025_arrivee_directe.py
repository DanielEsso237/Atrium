"""L'arrivee directe : un client sans reservation, en nuits ou en heures.

Un voyageur arrive et prend une chambre, pour des nuits ou pour quelques
heures, a un prix saisi librement (demande du 14 octobre). Sur
`reservation_rooms` :

- `is_walk_in` : le sejour est une arrivee directe ;
- `stay_unit` : NIGHTS ou HOURS. Tous les sejours existants sont en nuits ;
- `departure_at` : l'heure de depart d'un sejour en heures, instant UTC --
  `departure_date` est une date seule et ne peut pas la dire ;
- `rate_set_by` : qui a saisi un prix different du tarif de la categorie.

Revision ID: 0025_arrivee_directe
Revises: 0024_surclassement
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0025_arrivee_directe"
down_revision: Union[str, None] = "0024_surclassement"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "reservation_rooms",
        sa.Column("is_walk_in", sa.Boolean(), nullable=False, server_default="false"),
    )
    op.add_column(
        "reservation_rooms",
        sa.Column("stay_unit", sa.String(length=32), nullable=False, server_default="NIGHTS"),
    )
    op.add_column(
        "reservation_rooms",
        sa.Column("departure_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "reservation_rooms",
        sa.Column(
            "rate_set_by",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )


def downgrade() -> None:
    op.drop_column("reservation_rooms", "rate_set_by")
    op.drop_column("reservation_rooms", "departure_at")
    op.drop_column("reservation_rooms", "stay_unit")
    op.drop_column("reservation_rooms", "is_walk_in")
