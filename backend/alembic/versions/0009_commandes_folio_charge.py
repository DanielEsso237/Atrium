"""Le role Commandes porte folio.charge.

Porter une consommation sur une chambre ecrit sur l'ardoise : le role
Commandes (code RESTAURANT) avait order.create mais aucun droit sur
l'ardoise, et chaque consommation portee a une chambre etait refusee (403),
bloquant la file du comptoir.

folio.charge et non folio.write : folio.write sert aussi a encaisser et a
clore une ardoise, et ouvrirait au comptoir la caisse et les factures.
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0009_commandes_folio_charge"
down_revision: Union[str, None] = "0008_point_de_vente_par_defaut"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

PERMISSION_ID = "01920000-0000-7000-8000-000000004133"


def upgrade() -> None:
    op.execute(
        f"""
        INSERT INTO permissions (id, code, label, module)
        SELECT '{PERMISSION_ID}', 'folio.charge',
               'Porter une consommation sur une ardoise (sans encaisser)', 'folio'
         WHERE NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'folio.charge')
        """
    )
    # L'administrateur a toutes les permissions ; le comptoir porte.
    op.execute(
        """
        INSERT INTO role_permissions (role_id, permission_id)
        SELECT r.id, p.id FROM roles r, permissions p
         WHERE r.code IN ('ADMIN', 'RESTAURANT') AND p.code = 'folio.charge'
           AND NOT EXISTS (
                 SELECT 1 FROM role_permissions rp
                  WHERE rp.role_id = r.id AND rp.permission_id = p.id)
        """
    )


def downgrade() -> None:
    op.execute(
        """
        DELETE FROM role_permissions rp USING permissions p
         WHERE rp.permission_id = p.id AND p.code = 'folio.charge'
        """
    )
    op.execute("DELETE FROM permissions WHERE code = 'folio.charge'")
