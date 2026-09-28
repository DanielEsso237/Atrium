"""les arrhes passent par la caisse

- `payments.reservation_id` : des arrhes versees a la reservation, avant que
  l'ardoise n'existe. Nullable, indexe.
- `single_target` : un paiement a au plus un rattachement parmi ardoise,
  facture et reservation -- sinon le meme argent compterait deux fois.
- `uq_payments_reservation_pending` : un seul paiement d'arrhes en attente
  par reservation.

Revision ID: 0006_arrhes_en_caisse
Revises: 0005_seuil_consommation
Create Date: 2026-09-28
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0006_arrhes_en_caisse"
down_revision: Union[str, None] = "0005_seuil_consommation"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("payments", sa.Column("reservation_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        op.f("fk_payments_reservation_id"),
        "payments",
        "reservations",
        ["reservation_id"],
        ["id"],
        ondelete="RESTRICT",
    )
    op.create_index(op.f("ix_payments_reservation_id"), "payments", ["reservation_id"])
    op.create_check_constraint(
        op.f("ck_payments_single_target"),
        "payments",
        "num_nonnulls(folio_id, invoice_id, reservation_id) <= 1",
    )
    op.execute(
        """
        CREATE UNIQUE INDEX uq_payments_reservation_pending
        ON payments (reservation_id)
        WHERE reservation_id IS NOT NULL AND deleted_at IS NULL
        """
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS uq_payments_reservation_pending")
    op.drop_constraint(op.f("ck_payments_single_target"), "payments", type_="check")
    op.drop_index(op.f("ix_payments_reservation_id"), table_name="payments")
    op.drop_constraint(op.f("fk_payments_reservation_id"), "payments", type_="foreignkey")
    op.drop_column("payments", "reservation_id")
