"""Le role RESTAURANT s'appelle desormais « Points de vente ».

Retour du 8 octobre : le module Commandes devient Points de vente, et le
role qui y travaille suit. Libelle seulement : le code RESTAURANT ne change
pas, c'est lui que lisent le routeur et les rattachements aux points de
vente.
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0012_role_points_de_vente"
down_revision: Union[str, None] = "0011_commandes_caisse"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("UPDATE roles SET label = 'Points de vente' WHERE code = 'RESTAURANT'")


def downgrade() -> None:
    op.execute("UPDATE roles SET label = 'Commandes' WHERE code = 'RESTAURANT'")
