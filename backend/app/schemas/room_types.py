"""Schemas Pydantic pour le referentiel des types de chambres et tarifs."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, ConfigDict, Field


class RoomTypeIn(BaseModel):
    """Creation/mise a jour d'une categorie (admin).

    `default_rate` est le tarif de base affiche partout tant que le systeme
    de plans tarifaires saisonniers (rate_plans/rate_plan_prices, deja
    modelises) n'a pas d'ecran dedie -- prevu avec les reservations (Phase 2),
    pas avant : sans reservation pour les consommer, ces tarifs saisonniers ne
    controleraient encore rien.
    """

    code: str = Field(min_length=1, max_length=16)
    label: str = Field(min_length=1, max_length=80)
    description: str | None = None
    base_capacity: int = Field(default=2, ge=1)
    max_capacity: int = Field(default=2, ge=1)
    default_rate: int = Field(ge=0, description="Tarif en FCFA")
    sort_order: int = 0


class RoomTypeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    label: str
    description: str | None
    base_capacity: int
    max_capacity: int
    default_rate: int
    sort_order: int
