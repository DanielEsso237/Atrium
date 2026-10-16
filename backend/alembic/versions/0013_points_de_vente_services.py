"""points de vente / services, image et stock des articles

- outlets.kind : OUTLET (defaut, toutes les lignes existantes) ou SERVICE
- outlets.photo_path, outlets.stock_location_id
- menu_items.product_id : lien facultatif vers le produit suivi en stock

Revision ID: 0013_points_de_vente_services
Revises: 0012_role_points_de_vente
Create Date: 2026-10-08
"""

from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0013_points_de_vente_services"
down_revision: Union[str, None] = "0012_role_points_de_vente"
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
    op.add_column("outlets", sa.Column("photo_path", sa.String(length=255), nullable=True))
    op.add_column("outlets", sa.Column("stock_location_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        op.f("fk_outlets_stock_location_id"),
        "outlets",
        "stock_locations",
        ["stock_location_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.add_column("menu_items", sa.Column("product_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        op.f("fk_menu_items_product_id"),
        "menu_items",
        "products",
        ["product_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(op.f("ix_menu_items_product_id"), "menu_items", ["product_id"])


def downgrade() -> None:
    op.drop_index(op.f("ix_menu_items_product_id"), table_name="menu_items")
    op.drop_constraint(op.f("fk_menu_items_product_id"), "menu_items", type_="foreignkey")
    op.drop_column("menu_items", "product_id")
    op.drop_constraint(op.f("fk_outlets_stock_location_id"), "outlets", type_="foreignkey")
    op.drop_column("outlets", "stock_location_id")
    op.drop_column("outlets", "photo_path")
    op.drop_column("outlets", "kind")