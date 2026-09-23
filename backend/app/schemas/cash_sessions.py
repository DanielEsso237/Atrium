"""Schemas Pydantic pour les sessions de caisse (role Caissier, paragraphe 2)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import CashSessionStatus


class CashSessionOpenIn(BaseModel):
    opening_float: int = Field(ge=0, description="Fond de caisse, FCFA")
    device_id: uuid.UUID | None = None
    notes: str | None = None


class CashSessionCloseIn(BaseModel):
    counted_amount: int = Field(ge=0, description="Especes comptees, FCFA")
    notes: str | None = None


class CashSessionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    device_id: uuid.UUID | None
    status: CashSessionStatus
    opened_at: dt.datetime | None
    opening_float: int
    closed_at: dt.datetime | None
    # Session ouverte : attendu calcule a l'instant de la lecture.
    # Session close : fige a la fermeture.
    expected_amount: int
    counted_amount: int | None
    variance: int
    notes: str | None
