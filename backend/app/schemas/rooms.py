"""Schemas Pydantic pour l'hebergement (chambres)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import (
    ChargeCategory,
    HousekeepingStatus,
    OccupancyStatus,
    ReservationStatus,
)


class RoomTypeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    label: str
    default_rate: int


class FloorOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    label: str


class RoomOut(BaseModel):
    """Une ligne du plan de l'hotel (cahier des charges, paragraphe 5.2)."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    number: str
    occupancy_status: OccupancyStatus
    housekeeping_status: HousekeepingStatus
    is_out_of_order: bool
    display_status: str
    room_type: RoomTypeOut
    floor: FloorOut | None


class RoomIn(BaseModel):
    """Creation d'une chambre physique (admin)."""

    number: str = Field(min_length=1, max_length=16)
    room_type_id: uuid.UUID
    floor_id: uuid.UUID | None = None


class RoomUpdate(BaseModel):
    """PATCH d'une chambre (admin). Seuls les champs envoyes changent.

    Pas de `is_out_of_order` ici : ce drapeau est pilote par les tickets de
    maintenance bloquants (ouverture/cloture), le modifier a la main casserait
    ce chainage.
    """

    number: str | None = Field(default=None, min_length=1, max_length=16)
    room_type_id: uuid.UUID | None = None
    floor_id: uuid.UUID | None = None
    is_active: bool | None = None


class RoomStayOut(BaseModel):
    """Un sejour dans la chambre (en cours ou passe)."""

    reservation_id: uuid.UUID
    reservation_room_id: uuid.UUID
    reference: str
    guest_id: uuid.UUID
    guest_name: str
    arrival_date: dt.date
    departure_date: dt.date
    status: ReservationStatus
    checked_in_at: dt.datetime | None
    checked_out_at: dt.datetime | None


class RoomFolioOut(BaseModel):
    id: uuid.UUID
    number: str
    charges_total: int
    payments_total: int
    balance: int


class RoomChargeOut(BaseModel):
    id: uuid.UUID
    category: ChargeCategory
    label: str
    quantity: int
    amount: int
    business_date: dt.date
    posted_at: dt.datetime | None


class RoomDetailOut(RoomOut):
    """Fiche complete d'une chambre (paragraphe 5.2, panneau de detail)."""

    price: int
    floor_id: uuid.UUID | None
    is_active: bool
    out_of_order_reason: str | None
    out_of_order_until: dt.date | None
    notes: str | None
    current_stay: RoomStayOut | None = None
    folio: RoomFolioOut | None = None
    recent_charges: list[RoomChargeOut] = Field(default_factory=list)
    stay_history: list[RoomStayOut] = Field(default_factory=list)
