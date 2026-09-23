"""Schemas Pydantic pour les commandes restaurant (F3.1-F3.6)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import OrderStatus, OrderType


class OrderItemIn(BaseModel):
    menu_item_id: uuid.UUID
    quantity: int = Field(default=1, ge=1)
    notes: str | None = None


class OrderIn(BaseModel):
    outlet_id: uuid.UUID
    type: OrderType = OrderType.ON_SITE
    restaurant_table_id: uuid.UUID | None = None
    room_id: uuid.UUID | None = Field(
        default=None, description="Obligatoire si type=ROOM_SERVICE"
    )
    guest_id: uuid.UUID | None = None
    covers: int = Field(default=1, ge=1)
    notes: str | None = None
    items: list[OrderItemIn] = Field(min_length=1)


class OrderItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    menu_item_id: uuid.UUID | None
    prep_station_id: uuid.UUID | None
    label_snapshot: str
    quantity: int
    unit_price: int
    amount: int
    status: OrderStatus
    notes: str | None


class OrderOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    number: str
    outlet_id: uuid.UUID
    type: OrderType
    status: OrderStatus
    restaurant_table_id: uuid.UUID | None
    room_id: uuid.UUID | None
    folio_id: uuid.UUID | None
    guest_id: uuid.UUID | None
    covers: int
    subtotal: int
    tax_total: int
    total: int
    sent_at: dt.datetime | None
    served_at: dt.datetime | None
    cancelled_at: dt.datetime | None
    items: list[OrderItemOut]
