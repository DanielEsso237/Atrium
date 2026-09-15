"""Stocks : produits, magasins, mouvements, inventaires, fournisseurs."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    BigInteger,
    Boolean,
    Date,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import HotelScoped, RefBase, SyncBase
from app.models.enums import InventoryStatus, StockMovementType
from app.models.rooms import _enum


class Supplier(RefBase, HotelScoped):
    __tablename__ = "suppliers"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(160), index=True)
    contact_name: Mapped[str | None] = mapped_column(String(120), default=None)
    phone: Mapped[str | None] = mapped_column(String(40), default=None)
    email: Mapped[str | None] = mapped_column(String(160), default=None)
    address: Mapped[str | None] = mapped_column(String(255), default=None)
    tax_id: Mapped[str | None] = mapped_column(String(40), default=None)
    payment_terms_days: Mapped[int] = mapped_column(default=0)
    notes: Mapped[str | None] = mapped_column(Text, default=None)


class ProductCategory(RefBase, HotelScoped):
    __tablename__ = "product_categories"

    label: Mapped[str] = mapped_column(String(80))
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("product_categories.id", ondelete="SET NULL"), default=None
    )
    sort_order: Mapped[int] = mapped_column(default=0)


class Product(RefBase, HotelScoped):
    __tablename__ = "products"
    __table_args__ = (
        UniqueConstraint("hotel_id", "reference"),
        Index("ix_products_barcode", "barcode"),
    )

    reference: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(160), index=True)
    category_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("product_categories.id", ondelete="SET NULL"),
        default=None,
        index=True,
    )
    unit: Mapped[str] = mapped_column(String(16), default="U")
    barcode: Mapped[str | None] = mapped_column(String(64), default=None)
    purchase_price: Mapped[int] = mapped_column(BigInteger, default=0)
    sale_price: Mapped[int] = mapped_column(BigInteger, default=0)
    # Seuil d'alerte de reapprovisionnement.
    min_stock: Mapped[int] = mapped_column(Integer, default=0)
    # Vendable directement (minibar) par opposition a un consommable interne.
    is_sellable: Mapped[bool] = mapped_column(Boolean, default=False)
    default_supplier_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("suppliers.id", ondelete="SET NULL"), default=None
    )
    notes: Mapped[str | None] = mapped_column(Text, default=None)


class StockLocation(RefBase, HotelScoped):
    """Magasin : economat, cuisine, bar, lingerie."""

    __tablename__ = "stock_locations"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(80))
    manager_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    sort_order: Mapped[int] = mapped_column(default=0)


class StockLevel(SyncBase):
    """Quantite courante d'un produit dans un magasin.

    Table maintenue, et non vue calculee : une tablette doit afficher un stock
    hors ligne sans agreger tout l'historique des mouvements. `stock_movements`
    reste la source de verite -- ce compteur est reconstruit cote serveur en cas
    de divergence.
    """

    __tablename__ = "stock_levels"
    __table_args__ = (UniqueConstraint("product_id", "stock_location_id"),)

    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="CASCADE"), index=True
    )
    stock_location_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("stock_locations.id", ondelete="CASCADE"), index=True
    )
    quantity: Mapped[int] = mapped_column(Integer, default=0)
    last_movement_at: Mapped[dt.datetime | None] = mapped_column(default=None)


class StockMovement(SyncBase, HotelScoped):
    """Mouvement de stock : entree, sortie, transfert, ajustement, perte.

    Journal append-only : un mouvement erronne se corrige par un mouvement
    inverse, jamais par une modification. C'est la seule facon de garder un
    historique coherent quand plusieurs tablettes ecrivent hors ligne.
    """

    __tablename__ = "stock_movements"
    __table_args__ = (
        Index("ix_stock_movements_product_date", "product_id", "moved_at"),
        Index("ix_stock_movements_source", "source_table", "source_id"),
    )

    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="RESTRICT"), index=True
    )
    stock_location_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("stock_locations.id", ondelete="RESTRICT"), index=True
    )
    type: Mapped[StockMovementType] = mapped_column(
        _enum(StockMovementType, "stock_movement_type")
    )
    quantity: Mapped[int] = mapped_column(Integer)
    unit_cost: Mapped[int] = mapped_column(BigInteger, default=0)
    reason: Mapped[str | None] = mapped_column(String(255), default=None)
    # Magasin de destination pour un transfert.
    counterpart_location_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("stock_locations.id", ondelete="SET NULL"), default=None
    )
    supplier_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("suppliers.id", ondelete="SET NULL"), default=None
    )
    # Origine du mouvement : consommation housekeeping, vente minibar, casse.
    source_table: Mapped[str | None] = mapped_column(String(64), default=None)
    source_id: Mapped[uuid.UUID | None] = mapped_column(default=None)
    moved_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    moved_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )


class Inventory(SyncBase, HotelScoped):
    __tablename__ = "inventories"

    stock_location_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("stock_locations.id", ondelete="RESTRICT"), index=True
    )
    label: Mapped[str] = mapped_column(String(120))
    status: Mapped[InventoryStatus] = mapped_column(
        _enum(InventoryStatus, "inventory_status"), default=InventoryStatus.DRAFT
    )
    inventory_date: Mapped[dt.date | None] = mapped_column(Date, default=None)
    started_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    closed_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    closed_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    notes: Mapped[str | None] = mapped_column(Text, default=None)

    lines: Mapped[list[InventoryLine]] = relationship(
        back_populates="inventory", lazy="selectin"
    )


class InventoryLine(SyncBase):
    __tablename__ = "inventory_lines"
    __table_args__ = (UniqueConstraint("inventory_id", "product_id"),)

    inventory_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("inventories.id", ondelete="CASCADE"), index=True
    )
    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="RESTRICT"), index=True
    )
    # Quantite attendue, figee a l'ouverture de l'inventaire : la comparer a un
    # stock theorique recalcule apres coup n'aurait aucun sens, puisque le stock
    # bouge pendant le comptage.
    theoretical_qty: Mapped[int] = mapped_column(Integer, default=0)
    counted_qty: Mapped[int | None] = mapped_column(Integer, default=None)
    variance: Mapped[int] = mapped_column(Integer, default=0)
    comment: Mapped[str | None] = mapped_column(String(255), default=None)

    inventory: Mapped[Inventory] = relationship(back_populates="lines")
