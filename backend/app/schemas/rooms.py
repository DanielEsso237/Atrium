"""Schemas Pydantic pour l'hebergement (chambres)."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import HousekeepingStatus, OccupancyStatus


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
