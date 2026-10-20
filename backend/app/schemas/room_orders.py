"""Schemas Pydantic de la commande en chambre (F2.6)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import OrderStatus
from app.schemas.billing import PaymentIn


class RoomOrderLineIn(BaseModel):
    # L'id de la ligne devient celui de la ligne d'ardoise a la livraison :
    # la tablette qui livre hors ligne ecrit la meme ligne que le serveur.
    id: uuid.UUID = Field(description="UUID v7 genere par la tablette")
    menu_item_id: uuid.UUID
    quantity: int = Field(default=1, ge=1)
    notes: str | None = Field(default=None, max_length=255)


class RoomOrderIn(BaseModel):
    id: uuid.UUID = Field(description="UUID v7 genere par la tablette")
    outlet_id: uuid.UUID = Field(description="Le point de vente qui prepare et livre")
    folio_id: uuid.UUID = Field(description="L'ardoise ouverte du sejour (GET /chargeable-stays)")
    notes: str | None = None
    override_by: uuid.UUID | None = Field(
        default=None,
        description="Responsable (folio.override_limit) qui autorise le depassement du plafond",
    )
    items: list[RoomOrderLineIn] = Field(min_length=1)


class RoomOrderDeliverIn(BaseModel):
    # Le client paie a la livraison plutot que de laisser sur l'ardoise
    # (decision du client, 18 octobre) : le total de la commande, dans le
    # tiroir de celui qui livre. Absent, la commande reste due sur l'ardoise.
    payment: PaymentIn | None = Field(
        default=None,
        description="Le client paie maintenant : le total, dans le tiroir de celui qui livre",
    )


class RoomOrderCancelIn(BaseModel):
    reason: str = Field(min_length=1, max_length=255)


class RoomOrderLineOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    menu_item_id: uuid.UUID | None
    prep_station_id: uuid.UUID | None
    label_snapshot: str
    quantity: int
    unit_price: int
    tax_rate: int
    amount: int
    status: OrderStatus
    notes: str | None


class RoomOrderOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    number: str
    outlet_id: uuid.UUID
    status: OrderStatus
    room_id: uuid.UUID | None
    folio_id: uuid.UUID | None
    guest_id: uuid.UUID | None
    business_date: dt.date | None
    notes: str | None
    total: int
    tax_total: int
    ordered_by: uuid.UUID | None
    opened_at: dt.datetime | None
    taken_by: uuid.UUID | None
    taken_at: dt.datetime | None
    delivered_by: uuid.UUID | None
    served_at: dt.datetime | None
    cancelled_by: uuid.UUID | None
    cancelled_at: dt.datetime | None
    cancel_reason: str | None
    override_by: uuid.UUID | None
    updated_at: dt.datetime
    items: list[RoomOrderLineOut]
