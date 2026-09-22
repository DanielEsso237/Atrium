"""Schemas Pydantic pour le referentiel restauration (F3)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import TableStatus


class OutletIn(BaseModel):
    code: str = Field(min_length=1, max_length=32)
    label: str = Field(min_length=1, max_length=80)
    opens_at: dt.time | None = None
    closes_at: dt.time | None = None
    allows_room_charge: bool = True
    sort_order: int = 0


class OutletOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    label: str
    opens_at: dt.time | None
    closes_at: dt.time | None
    allows_room_charge: bool
    sort_order: int


class PrepStationIn(BaseModel):
    code: str = Field(min_length=1, max_length=32)
    label: str = Field(min_length=1, max_length=80)
    sort_order: int = 0


class PrepStationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    label: str
    sort_order: int


class RestaurantTableIn(BaseModel):
    outlet_id: uuid.UUID
    number: str = Field(min_length=1, max_length=16)
    capacity: int = Field(default=2, ge=1)
    zone: str | None = None
    map_x: int | None = None
    map_y: int | None = None


class RestaurantTableOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    outlet_id: uuid.UUID
    number: str
    capacity: int
    zone: str | None
    status: TableStatus
    map_x: int | None
    map_y: int | None


class MenuCategoryIn(BaseModel):
    outlet_id: uuid.UUID | None = None
    label: str = Field(min_length=1, max_length=80)
    sort_order: int = 0


class MenuCategoryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    outlet_id: uuid.UUID | None
    label: str
    sort_order: int


class MenuItemIn(BaseModel):
    """`prep_station_id` a None : l'article ne genere aucun ticket de

    production (droit d'entree, acces piscine...) -- voir le commentaire du
    modele `MenuItem` pour la regle R1 que ce champ met en oeuvre.
    """

    code: str = Field(min_length=1, max_length=32)
    label: str = Field(min_length=1, max_length=160)
    description: str | None = None
    menu_category_id: uuid.UUID
    prep_station_id: uuid.UUID | None = None
    price: int = Field(ge=0, description="FCFA")
    tax_rate: int = Field(default=0, ge=0, le=100, description="Pourcentage")
    is_available: bool = True
    preparation_minutes: int | None = Field(default=None, ge=0)


class MenuItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    label: str
    description: str | None
    menu_category_id: uuid.UUID
    prep_station_id: uuid.UUID | None
    price: int
    tax_rate: int
    is_available: bool
    preparation_minutes: int | None
