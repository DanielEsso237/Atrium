"""Schemas Pydantic pour les sessions de caisse (role Caissier, paragraphe 2)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import CashSessionStatus


class CashSessionOpenIn(BaseModel):
    # L'identifiant choisi par la tablette. Sans lui, la caisse naissait sous
    # un autre identifiant sur le serveur, et la fermeture envoyee ensuite ne
    # la retrouvait pas.
    id: uuid.UUID | None = None
    opening_float: int = Field(ge=0, description="Fond de caisse, FCFA")
    device_id: uuid.UUID | None = None
    # Le point de vente dont c'est le tiroir ; absent pour la caisse centrale.
    outlet_id: uuid.UUID | None = None
    notes: str | None = None


class CashSessionCloseIn(BaseModel):
    counted_amount: int = Field(ge=0, description="Especes comptees, FCFA")
    notes: str | None = None


class CashSessionReceiveIn(BaseModel):
    received_amount: int = Field(ge=0, description="Especes recues par la reception, FCFA")


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
    # Le versement du soir d'un point de vente (nuls pour la caisse centrale).
    outlet_id: uuid.UUID | None = None
    received_amount: int | None = None
    received_by: uuid.UUID | None = None
    received_at: dt.datetime | None = None
    received_session_id: uuid.UUID | None = None
