"""Le nom d'une ardoise du comptoir.

Le tenant d'un point de vente remplace « Client divers n°3 » par un nom qui
l'aide a reconnaitre son client : « Table 4 » (demande du 14 octobre).

- `folios.tab_label` : ce nom, 60 caracteres au plus. Nul par defaut : la
  tablette compose alors le nom avec le numero, qui reste dans tous les cas.

Revision ID: 0023_nom_ardoise_comptoir
Revises: 0022_cout_moyen_et_comptabilite
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0023_nom_ardoise_comptoir"
down_revision: Union[str, None] = "0022_cout_moyen_et_comptabilite"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("folios", sa.Column("tab_label", sa.String(length=60), nullable=True))


def downgrade() -> None:
    op.drop_column("folios", "tab_label")
