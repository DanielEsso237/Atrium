"""Un article de la carte peut etre relie a un produit en stock.

Pour qu'une vente fasse sortir le stock du point de vente : la biere vendue au
bar quitte le stock du bar. `stock_quantity` dit combien de produit sort par
article vendu (1 par defaut). Un article sans produit (plat du jour, entree en
boite) ne touche a aucun stock.

Revision ID: 0015_article_relie_au_stock
Revises: 0014_transferts_a_valider
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0015_article_relie_au_stock"
down_revision: Union[str, None] = "0014_transferts_a_valider"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("menu_items", sa.Column("product_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_menu_items_product_id", "menu_items", "products",
        ["product_id"], ["id"], ondelete="SET NULL",
    )
    op.add_column(
        "menu_items",
        sa.Column("stock_quantity", sa.Integer(), nullable=False, server_default="1"),
    )


def downgrade() -> None:
    op.drop_constraint("fk_menu_items_product_id", "menu_items", type_="foreignkey")
    op.drop_column("menu_items", "stock_quantity")
    op.drop_column("menu_items", "product_id")
