"""Le role Commandes ouvre une caisse.

Decision du 4 octobre : le client de passage (il mange ou boit sans
chambre, paie et s'en va) est encaisse par le bar ou le restaurant, pas
par la reception. Le comptoir encaisse donc, et un encaissement se
rattache a la caisse ouverte de celui qui le recoit : sans cash.session,
l'argent existait sans etre dans aucun tiroir, et la fin de service ne
tombait jamais juste.

folio.write reste hors du comptoir : la vente de passage passe par sa
propre route (POST /folios/walk-in), qui n'ouvre ni les factures ni les
ardoises des chambres.
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0011_commandes_caisse"
down_revision: Union[str, None] = "0010_role_commandes"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        INSERT INTO role_permissions (role_id, permission_id)
        SELECT r.id, p.id FROM roles r, permissions p
         WHERE r.code = 'RESTAURANT' AND p.code = 'cash.session'
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
           AND r.code = 'RESTAURANT' AND p.code = 'cash.session'
        """
    )
