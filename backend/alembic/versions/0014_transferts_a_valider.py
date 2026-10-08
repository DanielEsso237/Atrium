"""Les transferts de stock attendent une validation.

Retours du 7 octobre : tout envoi de l'economat vers un point de vente, et
tout transfert entre points de vente, est valide par le controleur ou le
comptable -- un seul des deux suffit. Le stock ne bouge qu'a la validation.

Schema : `stock_movements.status` (PENDING, APPROVED, REJECTED) et la
decision (qui, quand, motif). Les mouvements deja enregistres ont ete
appliques : ils deviennent APPROVED.

Donnees : la permission `stock.transfer.approve`, donnee a l'administrateur.
Les roles controleur et comptable viendront avec leur propre migration.

Revision ID: 0014_transferts_a_valider
Revises: 0013_economat_et_magasins
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0014_transferts_a_valider"
down_revision: Union[str, None] = "0013_economat_et_magasins"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

PERMISSION_ID = "01920000-0000-7000-8000-000000004134"

# Comme les autres enumerations du schema : du texte, pas un ENUM natif.
statut = sa.Enum(
    "PENDING", "APPROVED", "REJECTED",
    name="stock_movement_status", native_enum=False, length=32,
)


def upgrade() -> None:
    op.add_column(
        "stock_movements",
        sa.Column("status", statut, nullable=False, server_default="APPROVED"),
    )
    op.add_column("stock_movements", sa.Column("decided_by", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_stock_movements_decided_by", "stock_movements", "users",
        ["decided_by"], ["id"], ondelete="SET NULL",
    )
    op.add_column(
        "stock_movements", sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.add_column("stock_movements", sa.Column("decision_note", sa.String(255), nullable=True))

    op.execute(
        f"""
        INSERT INTO permissions (id, code, label, module)
        SELECT '{PERMISSION_ID}', 'stock.transfer.approve',
               'Valider ou refuser un transfert de stock', 'stock'
         WHERE NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'stock.transfer.approve')
        """
    )
    op.execute(
        """
        INSERT INTO role_permissions (role_id, permission_id)
        SELECT r.id, p.id FROM roles r, permissions p
         WHERE r.code = 'ADMIN' AND p.code = 'stock.transfer.approve'
           AND NOT EXISTS (
                 SELECT 1 FROM role_permissions rp
                  WHERE rp.role_id = r.id AND rp.permission_id = p.id)
        """
    )


def downgrade() -> None:
    op.execute(
        """
        DELETE FROM role_permissions rp USING permissions p
         WHERE rp.permission_id = p.id AND p.code = 'stock.transfer.approve'
        """
    )
    op.execute("DELETE FROM permissions WHERE code = 'stock.transfer.approve'")
    op.drop_constraint("fk_stock_movements_decided_by", "stock_movements", type_="foreignkey")
    for colonne in ("decision_note", "decided_at", "decided_by", "status"):
        op.drop_column("stock_movements", colonne)
