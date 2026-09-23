"""Schemas Pydantic pour la maintenance (F2.3, F4.1-F4.4)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import Priority, TicketStatus


class MaintenanceTicketIn(BaseModel):
    """`blocks_room` sort immediatement la chambre de la vente (voir le

    commentaire du modele `MaintenanceTicket`) -- une fuite d'eau coche cette
    case, une ampoule grillee non.
    """

    room_id: uuid.UUID | None = None
    equipment_id: uuid.UUID | None = None
    location: str | None = None
    category: str | None = None
    title: str = Field(min_length=1, max_length=160)
    description: str | None = None
    priority: Priority = Priority.NORMAL
    blocks_room: bool = False


class MaintenanceTicketOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    number: str
    room_id: uuid.UUID | None
    equipment_id: uuid.UUID | None
    title: str
    description: str | None
    priority: Priority
    status: TicketStatus
    reported_by: uuid.UUID | None
    reported_at: dt.datetime | None
    assigned_to: uuid.UUID | None
    resolved_at: dt.datetime | None
    closed_at: dt.datetime | None
    resolution: str | None
    cost: int
    blocks_room: bool


class AssignIn(BaseModel):
    user_id: uuid.UUID


class InterventionIn(BaseModel):
    description: str | None = None
    cost: int = Field(default=0, ge=0)


class InterventionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    technician_id: uuid.UUID | None
    started_at: dt.datetime | None
    ended_at: dt.datetime | None
    description: str | None
    cost: int


class ResolveIn(BaseModel):
    resolution: str = Field(min_length=1)
