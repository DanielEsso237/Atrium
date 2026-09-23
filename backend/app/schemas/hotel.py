"""Schemas Pydantic pour le parametrage de l'etablissement."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, ConfigDict, Field


class HotelOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    name: str
    legal_name: str | None
    address: str | None
    city: str | None
    postal_code: str | None
    country: str | None
    phone: str | None
    email: str | None
    website: str | None
    tax_id: str | None
    timezone: str
    currency: str
    day_rollover_hour: int


class HotelUpdate(BaseModel):
    """Le `code` n'est pas modifiable ici : c'est un identifiant stable,

    utilise ailleurs (imports, integrations) -- le changer demande une
    decision deliberee, pas un champ de formulaire comme un autre.
    """

    name: str = Field(min_length=1, max_length=160)
    legal_name: str | None = None
    address: str | None = None
    city: str | None = None
    postal_code: str | None = None
    country: str | None = None
    phone: str | None = None
    email: str | None = None
    website: str | None = None
    tax_id: str | None = None
    timezone: str = "Africa/Abidjan"
    currency: str = "XOF"
    day_rollover_hour: int = Field(default=6, ge=0, le=23)
