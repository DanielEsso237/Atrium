"""Points de vente et services.

Retour du 9 octobre : a cote des points de vente (restaurant, bar,
boutique), l'hotel vend des prestations -- spa, piscine, salle de sport,
salle de conference. Meme saisie, meme facturation ; un onglet a part.

`outlets.kind` : OUTLET (par defaut, tous les points de vente existants) ou
SERVICE.

Revision ID: 0016_services
Revises: 0015_article_relie_au_stock
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0016_services"
down_revision: Union[str, None] = "0015_article_relie_au_stock"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "outlets",
        sa.Column(
            "kind",
            sa.Enum("OUTLET", "SERVICE", name="outlet_kind", native_enum=False, length=32),
            nullable=False,
            server_default="OUTLET",
        ),
    )


def downgrade() -> None:
    op.drop_column("outlets", "kind")
