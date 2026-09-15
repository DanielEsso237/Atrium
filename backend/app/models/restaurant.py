"""Restauration : points de vente, stations, menu, commandes."""

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
    Time,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import HotelScoped, RefBase, SyncBase
from app.models.enums import OrderStatus, OrderType, TableStatus
from app.models.rooms import _enum


class Outlet(RefBase, HotelScoped):
    """Point de vente : restaurant, bar, piscine, room service (F3.1)."""

    __tablename__ = "outlets"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(80))
    opens_at: Mapped[dt.time | None] = mapped_column(Time, default=None)
    closes_at: Mapped[dt.time | None] = mapped_column(Time, default=None)
    allows_room_charge: Mapped[bool] = mapped_column(Boolean, default=True)
    sort_order: Mapped[int] = mapped_column(default=0)


class PrepStation(RefBase, HotelScoped):
    """Poste de preparation : cuisine, bar, patisserie.

    Cette table est la charniere du routage d'impression. Elle est distincte
    du point de vente parce que la relation n'est pas un a un : une commande
    prise au bord de la piscine peut avoir des plats prepares en cuisine et des
    boissons preparees au bar.
    """

    __tablename__ = "prep_stations"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(80))
    sort_order: Mapped[int] = mapped_column(default=0)
    # L'imprimante cible se resout via `print_routes` (regle R5, routage
    # configurable) et non par une colonne en dur ici : une seule table de
    # routage, editable depuis l'administration.


class RestaurantTable(RefBase, HotelScoped):
    __tablename__ = "restaurant_tables"
    __table_args__ = (UniqueConstraint("outlet_id", "number"),)

    outlet_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("outlets.id", ondelete="CASCADE"), index=True
    )
    number: Mapped[str] = mapped_column(String(16))
    capacity: Mapped[int] = mapped_column(default=2)
    zone: Mapped[str | None] = mapped_column(String(64), default=None)
    status: Mapped[TableStatus] = mapped_column(
        _enum(TableStatus, "table_status"), default=TableStatus.FREE
    )
    map_x: Mapped[int | None] = mapped_column(default=None)
    map_y: Mapped[int | None] = mapped_column(default=None)


class MenuCategory(RefBase, HotelScoped):
    __tablename__ = "menu_categories"

    outlet_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("outlets.id", ondelete="CASCADE"), default=None, index=True
    )
    label: Mapped[str] = mapped_column(String(80))
    sort_order: Mapped[int] = mapped_column(default=0)
    photo_path: Mapped[str | None] = mapped_column(String(255), default=None)


class MenuItem(RefBase, HotelScoped):
    """Article du menu (F3.5).

    `prep_station_id` est la colonne la plus importante de ce module. En
    attachant le poste de preparation a l'article plutot qu'a la commande, la
    regle R1 du cahier des charges -- un ticket cuisine ne doit *jamais* partir
    au bar -- devient une consequence du modele de donnees et non une regle
    applicative qu'un developpeur peut oublier.

    Une commande mixte se scinde alors automatiquement en un ticket cuisine et
    un ticket bar, simplement parce que ses lignes pointent vers des stations
    differentes.
    """

    __tablename__ = "menu_items"
    __table_args__ = (
        UniqueConstraint("hotel_id", "code"),
        Index("ix_menu_items_prep_station_id", "prep_station_id"),
    )

    code: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(160))
    description: Mapped[str | None] = mapped_column(Text, default=None)
    menu_category_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("menu_categories.id", ondelete="RESTRICT"), index=True
    )
    # Nullable : tout ce qui se vend ne se prepare pas.
    #
    # Un droit d'entree en boite de nuit, un acces piscine, un depot de
    # vestiaire ou une bouteille vendue telle quelle n'ont aucun poste de
    # preparation, et ne doivent produire aucun ticket de production.
    #
    # La regle R1 n'en est pas affaiblie : elle dit qu'un ticket ne doit pas
    # partir au mauvais poste, pas qu'il doive exister un ticket pour tout.
    # Une ligne sans poste est simplement ignoree par le routage.
    prep_station_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("prep_stations.id", ondelete="RESTRICT"), default=None
    )
    price: Mapped[int] = mapped_column(BigInteger, default=0)
    tax_rate: Mapped[int] = mapped_column(Integer, default=0)
    # Rupture ponctuelle, distincte de `is_active` qui retire l'article du menu.
    is_available: Mapped[bool] = mapped_column(Boolean, default=True)
    preparation_minutes: Mapped[int | None] = mapped_column(default=None)
    allergens: Mapped[dict | None] = mapped_column(JSONB, default=None)
    photo_path: Mapped[str | None] = mapped_column(String(255), default=None)
    sort_order: Mapped[int] = mapped_column(default=0)


class MenuItemOption(RefBase):
    """Option ou variante : cuisson, accompagnement, supplement."""

    __tablename__ = "menu_item_options"

    menu_item_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("menu_items.id", ondelete="CASCADE"), index=True
    )
    group_label: Mapped[str | None] = mapped_column(String(80), default=None)
    label: Mapped[str] = mapped_column(String(120))
    price_delta: Mapped[int] = mapped_column(BigInteger, default=0)
    is_required: Mapped[bool] = mapped_column(Boolean, default=False)
    sort_order: Mapped[int] = mapped_column(default=0)


class Order(SyncBase, HotelScoped):
    """Commande (F3.1 a F3.6)."""

    __tablename__ = "orders"
    __table_args__ = (
        UniqueConstraint("hotel_id", "number"),
        Index("ix_orders_status", "status"),
        Index("ix_orders_business_date", "business_date"),
    )

    number: Mapped[str] = mapped_column(String(32))
    outlet_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("outlets.id", ondelete="RESTRICT"), index=True
    )
    type: Mapped[OrderType] = mapped_column(
        _enum(OrderType, "order_type"), default=OrderType.ON_SITE
    )
    status: Mapped[OrderStatus] = mapped_column(
        _enum(OrderStatus, "order_status"), default=OrderStatus.DRAFT
    )

    restaurant_table_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("restaurant_tables.id", ondelete="SET NULL"), default=None
    )
    # Room service : la commande vise une chambre et se reporte sur son folio.
    room_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rooms.id", ondelete="SET NULL"), default=None, index=True
    )
    folio_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("folios.id", ondelete="SET NULL"), default=None, index=True
    )
    guest_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("guests.id", ondelete="SET NULL"), default=None
    )
    waiter_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None, index=True
    )

    covers: Mapped[int] = mapped_column(default=1)
    business_date: Mapped[dt.date | None] = mapped_column(Date, default=None)
    opened_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    # Passage de DRAFT a SENT : c'est cet instant qui declenche l'emission des
    # tickets vers les postes de preparation (F3.2).
    sent_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    ready_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    served_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    cancelled_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    cancel_reason: Mapped[str | None] = mapped_column(String(255), default=None)

    subtotal: Mapped[int] = mapped_column(BigInteger, default=0)
    tax_total: Mapped[int] = mapped_column(BigInteger, default=0)
    discount_total: Mapped[int] = mapped_column(BigInteger, default=0)
    total: Mapped[int] = mapped_column(BigInteger, default=0)
    notes: Mapped[str | None] = mapped_column(Text, default=None)

    items: Mapped[list[OrderItem]] = relationship(
        back_populates="order", lazy="selectin"
    )


class OrderItem(SyncBase):
    """Ligne de commande.

    `label_snapshot`, `unit_price` et `prep_station_id` sont recopies depuis
    l'article du menu au moment de la prise de commande. Cette duplication est
    voulue : une commande deja imprimee et facturee ne doit pas changer
    retroactivement parce que le gerant a modifie le prix ou renomme le plat
    une heure plus tard.
    """

    __tablename__ = "order_items"
    __table_args__ = (
        Index("ix_order_items_prep_station_status", "prep_station_id", "status"),
    )

    order_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("orders.id", ondelete="CASCADE"), index=True
    )
    menu_item_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("menu_items.id", ondelete="SET NULL"), default=None
    )
    # Nul pour un article sans preparation (cf. `MenuItem.prep_station_id`).
    prep_station_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("prep_stations.id", ondelete="RESTRICT"), default=None
    )

    label_snapshot: Mapped[str] = mapped_column(String(160))
    quantity: Mapped[int] = mapped_column(Integer, default=1)
    unit_price: Mapped[int] = mapped_column(BigInteger, default=0)
    tax_rate: Mapped[int] = mapped_column(Integer, default=0)
    amount: Mapped[int] = mapped_column(BigInteger, default=0)

    status: Mapped[OrderStatus] = mapped_column(
        _enum(OrderStatus, "order_status"), default=OrderStatus.DRAFT
    )
    # Instructions au poste de preparation : "sans oignon", "bien cuit".
    notes: Mapped[str | None] = mapped_column(String(255), default=None)
    sent_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    ready_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    is_void: Mapped[bool] = mapped_column(Boolean, default=False)
    void_reason: Mapped[str | None] = mapped_column(String(255), default=None)
    sort_order: Mapped[int] = mapped_column(default=0)

    order: Mapped[Order] = relationship(back_populates="items")
    options: Mapped[list[OrderItemOption]] = relationship(
        back_populates="order_item", lazy="selectin"
    )


class OrderItemOption(SyncBase):
    __tablename__ = "order_item_options"

    order_item_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("order_items.id", ondelete="CASCADE"), index=True
    )
    menu_item_option_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("menu_item_options.id", ondelete="SET NULL"), default=None
    )
    label_snapshot: Mapped[str] = mapped_column(String(120))
    price_delta: Mapped[int] = mapped_column(BigInteger, default=0)

    order_item: Mapped[OrderItem] = relationship(back_populates="options")
