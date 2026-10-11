"""Une caisse ouverte par agent et par tiroir.

Decision du 11 octobre : chaque point de vente a son tiroir, ouvert et ferme
independamment. Paul tient le Bar / Lounge et le Bar piscine ; il ferme la
piscine a 22 h sans fermer le lounge. L'index unique passe de « une session
ouverte par agent » a « une par agent et par tiroir », la caisse centrale
(outlet_id nul) comptant comme un tiroir.

Revision ID: 0020_caisse_par_point_de_vente
Revises: 0019_roles_du_stock
"""

from typing import Sequence, Union

from alembic import op

revision: str = "0020_caisse_par_point_de_vente"
down_revision: Union[str, None] = "0019_roles_du_stock"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("DROP INDEX IF EXISTS uq_cash_sessions_user_open")
    op.execute(
        """
        CREATE UNIQUE INDEX uq_cash_sessions_user_outlet_open
            ON cash_sessions (
                user_id,
                coalesce(outlet_id, '00000000-0000-0000-0000-000000000000'::uuid)
            )
         WHERE status = 'OPEN' AND deleted_at IS NULL
        """
    )


def downgrade() -> None:
    # Echoue si un agent tient encore plusieurs tiroirs ouverts : il faut
    # les fermer avant de revenir en arriere.
    op.execute("DROP INDEX IF EXISTS uq_cash_sessions_user_outlet_open")
    op.execute(
        """
        CREATE UNIQUE INDEX uq_cash_sessions_user_open
            ON cash_sessions (user_id)
         WHERE status = 'OPEN' AND deleted_at IS NULL
        """
    )
