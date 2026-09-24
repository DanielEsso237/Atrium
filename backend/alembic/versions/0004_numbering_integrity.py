"""numerotation par sequence et garde-fous d'integrite

1. Initialise `number_sequences` pour les portees qui passaient jusqu'ici par
   `COUNT(*) + 1` (reservations, folios, commandes, clients, tickets) : chaque
   compteur repart du plus grand numero deja emis, par hotel. Sans cela, la
   premiere reservation creee apres la migration recevrait RES-000001, deja
   pris, et echouerait sur la contrainte unique.
2. Un seul folio vivant par sejour (index unique partiel).
3. Une seule session de caisse ouverte par caissier (index unique partiel).

Rejouable : l'initialisation prend le maximum entre le compteur existant et
les donnees, elle ne fait jamais reculer une sequence.

Revision ID: 0004_numbering_integrity
Revises: 0003_dashboard_views
Create Date: 2026-09-23
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0004_numbering_integrity"
down_revision: Union[str, None] = "0003_dashboard_views"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# (portee, prefixe, table, colonne) -- les prefixes sont ceux de
# app/services/numbering.py, que les anciens COUNT emettaient deja.
SCOPES = [
    ("INVOICE", "FA-", "invoices", "number"),
    ("RESERVATION", "RES-", "reservations", "reference"),
    ("FOLIO", "FOL-", "folios", "number"),
    ("ORDER", "ORD-", "orders", "number"),
    ("GUEST", "CLI-", "guests", "code"),
    ("MAINTENANCE_TICKET", "TCK-", "maintenance_tickets", "number"),
]


def upgrade() -> None:
    for scope, prefix, table, column in SCOPES:
        pattern = f"^{prefix}([0-9]+)$"
        op.execute(
            f"""
            INSERT INTO number_sequences
                (id, hotel_id, scope, period, prefix, padding, current_value)
            SELECT gen_random_uuid(), hotel_id, '{scope}', 'ALL', '{prefix}', 6,
                   MAX((substring({column} FROM '{pattern}'))::bigint)
            FROM {table}
            WHERE {column} ~ '{pattern}'
            GROUP BY hotel_id
            ON CONFLICT (hotel_id, scope, period) DO UPDATE
            SET current_value = GREATEST(
                number_sequences.current_value, EXCLUDED.current_value
            )
            """
        )

    op.execute(
        """
        CREATE UNIQUE INDEX uq_folios_reservation_room_active
        ON folios (reservation_room_id)
        WHERE reservation_room_id IS NOT NULL AND deleted_at IS NULL
        """
    )
    op.execute(
        """
        CREATE UNIQUE INDEX uq_cash_sessions_user_open
        ON cash_sessions (user_id)
        WHERE status = 'OPEN' AND deleted_at IS NULL
        """
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS uq_cash_sessions_user_open")
    op.execute("DROP INDEX IF EXISTS uq_folios_reservation_room_active")
    # Les compteurs initialises restent : les supprimer ferait reemettre des
    # numeros deja attribues si l'on remontait ensuite.
