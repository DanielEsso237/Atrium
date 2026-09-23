"""Schemas Pydantic pour les reservations (F1.1-F1.3 du cahier des charges)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.models.enums import ReservationSource, ReservationStatus


class ReservationRoomIn(BaseModel):
    room_type_id: uuid.UUID
    arrival_date: dt.date
    departure_date: dt.date
    adults: int = Field(default=1, ge=1)
    children: int = Field(default=0, ge=0)
    nightly_rate: int | None = Field(
        default=None, ge=0, description="FCFA ; par defaut, le tarif de base du type de chambre"
    )

    @model_validator(mode="after")
    def _check_dates(self) -> "ReservationRoomIn":
        if self.departure_date <= self.arrival_date:
            raise ValueError("La date de depart doit etre posterieure a la date d'arrivee.")
        return self


class ReservationIn(BaseModel):
    guest_id: uuid.UUID
    source: ReservationSource = ReservationSource.DIRECT
    adults: int = Field(default=1, ge=1)
    children: int = Field(default=0, ge=0)
    special_requests: str | None = None
    internal_notes: str | None = None
    rooms: list[ReservationRoomIn] = Field(min_length=1)


class ReservationRoomOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    room_type_id: uuid.UUID
    room_id: uuid.UUID | None
    arrival_date: dt.date
    departure_date: dt.date
    adults: int
    children: int
    nightly_rate: int
    status: ReservationStatus
    checked_in_at: dt.datetime | None
    checked_out_at: dt.datetime | None
    key_card_code: str | None


class ReservationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    reference: str
    guest_id: uuid.UUID
    source: ReservationSource
    status: ReservationStatus
    arrival_date: dt.date
    departure_date: dt.date
    adults: int
    children: int
    estimated_total: int
    special_requests: str | None
    internal_notes: str | None
    cancelled_at: dt.datetime | None
    cancel_reason: str | None
    rooms: list[ReservationRoomOut]


class AvailabilityOut(BaseModel):
    room_type_id: uuid.UUID
    arrival_date: dt.date
    departure_date: dt.date
    total_rooms: int
    booked_rooms: int
    available_rooms: int


class CheckInIn(BaseModel):
    room_id: uuid.UUID | None = Field(
        default=None, description="Obligatoire si aucune chambre n'a encore ete assignee"
    )
    key_card_code: str | None = None


class CancelIn(BaseModel):
    reason: str | None = None


class ReservationRoomUpdate(BaseModel):
    """Modification d'une ligne (F1.1). Seuls les champs envoyes changent."""

    id: uuid.UUID
    room_type_id: uuid.UUID | None = None
    arrival_date: dt.date | None = None
    departure_date: dt.date | None = None
    adults: int | None = Field(default=None, ge=1)
    children: int | None = Field(default=None, ge=0)
    nightly_rate: int | None = Field(
        default=None, ge=0, description="FCFA ; sur changement de type, tarif du nouveau type"
    )


class ReservationUpdate(BaseModel):
    """PATCH /reservations/{id} : entete du dossier et/ou lignes a modifier."""

    adults: int | None = Field(default=None, ge=1)
    children: int | None = Field(default=None, ge=0)
    special_requests: str | None = None
    internal_notes: str | None = None
    rooms: list[ReservationRoomUpdate] = Field(default_factory=list)


class CalendarCell(BaseModel):
    """Une chambre un jour donne ; champs de sejour a null si la chambre est libre."""

    room_id: uuid.UUID
    room_number: str
    date: dt.date
    reservation_room_id: uuid.UUID | None = None
    reservation_id: uuid.UUID | None = None
    reference: str | None = None
    guest_name: str | None = None
    status: ReservationStatus | None = None


class CalendarUnassigned(BaseModel):
    """Ligne de reservation sans chambre physique : placee par type, pas par numero."""

    reservation_room_id: uuid.UUID
    reservation_id: uuid.UUID
    reference: str
    guest_name: str
    room_type_id: uuid.UUID
    arrival_date: dt.date
    departure_date: dt.date
    status: ReservationStatus


class CalendarOut(BaseModel):
    date_from: dt.date
    date_to: dt.date
    rows: list[CalendarCell]
    unassigned: list[CalendarUnassigned]
