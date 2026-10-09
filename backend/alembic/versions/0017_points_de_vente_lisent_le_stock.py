"""Le role Points de vente lit le stock de ses points de vente.

Retour du 9 octobre : le barman voit le stock du bar, l'agent de la boite
celui de la boite. Lecture seulement (stock.read) ; c'est la tablette qui ne
lui montre que les magasins de ses points de vente, comme ses onglets de
vente.

Revision ID: 0017_points_de_vente_lisent_le_stock
Revises: 0016_services
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0017_points_de_vente_lisent_le_stock"
down_revision: Union[str, None] = "0016_services"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        INSERT INTO role_permissions (role_id, permission_id)
        SELECT r.id, p.id FROM roles r, permissions p
         WHERE r.code = 'RESTAURANT' AND p.code = 'stock.read'
           AND NOT EXISTS (
                 SELECT 1 FROM role_permissions rp
                  WHERE rp.role_id = r.id AND rp.permission_id = p.id)
        """
    )


def downgrade() -> None:
    op.execute(
        """
        DELETE FROM role_permissions rp USING roles r, permissions p
         WHERE rp.role_id = r.id AND rp.permission_id = p.id
           AND r.code = 'RESTAURANT' AND p.code = 'stock.read'
        """
    )
