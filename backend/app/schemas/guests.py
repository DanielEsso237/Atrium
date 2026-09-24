"""Schemas Pydantic pour les clients (F1.6)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import IdDocumentType


class GuestIn(BaseModel):
    """Payload de creation/mise a jour d'une fiche client.

    Tous les champs sont optionnels sauf nom/prenom : une reception peut
    ouvrir une fiche minimale a l'arrivee et la completer plus tard, plutot
    que de bloquer le check-in en attendant une adresse complete.
    """

    # Cle generee hors ligne par la tablette (app/core/ids.py). Un renvoi du
    # meme id met la fiche a jour au lieu d'en creer une seconde.
    id: uuid.UUID | None = Field(default=None, description="UUID v7 genere par la tablette ; absent = genere par le serveur")
    first_name: str = Field(min_length=1, max_length=80)
    last_name: str = Field(min_length=1, max_length=80)
    title: str | None = None
    birth_date: dt.date | None = None
    birth_place: str | None = None
    nationality: str | None = None
    gender: str | None = None
    id_document_type: IdDocumentType | None = None
    id_document_number: str | None = None
    id_document_expiry: dt.date | None = None
    email: str | None = None
    phone: str | None = None
    phone_alt: str | None = None
    address: str | None = None
    city: str | None = None
    postal_code: str | None = None
    country: str | None = None
    company_id: uuid.UUID | None = None
    preferences: dict | None = None
    notes: str | None = None
    is_vip: bool = False
    marketing_consent: bool = False


class GuestOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    full_name: str
    title: str | None
    first_name: str
    last_name: str
    birth_date: dt.date | None
    nationality: str | None
    id_document_type: IdDocumentType | None
    id_document_number: str | None
    email: str | None
    phone: str | None
    address: str | None
    city: str | None
    country: str | None
    company_id: uuid.UUID | None
    is_vip: bool
    is_blacklisted: bool
    notes: str | None
