"""Schemas Pydantic de l'inventaire d'un magasin (ticket O4, 15 octobre)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import InventoryStatus


class InventoryLineIn(BaseModel):
    """Une ligne a compter : la tablette en donne l'id, le serveur la quantite."""

    id: uuid.UUID
    product_id: uuid.UUID


class InventoryIn(BaseModel):
    """Ouvrir l'inventaire d'un magasin, avec les articles a compter.

    La quantite theorique n'y est pas : le serveur fige la sienne a
    reception. La tablette peut ignorer une vente faite sur un autre poste.
    """

    id: uuid.UUID
    stock_location_id: uuid.UUID
    label: str = Field(min_length=1, max_length=120)
    lines: list[InventoryLineIn] = Field(min_length=1)


class InventoryCountIn(BaseModel):
    """Ce qui a ete compte ; `null` efface le comptage."""

    counted_qty: int | None = Field(default=None, ge=0)


class InventoryRebalanceIn(BaseModel):
    """Les identifiants des mouvements, choisis par la tablette.

    Un par produit dont l'ecart n'est pas nul : la tablette a deja ecrit ces
    mouvements chez elle, avec ces ids. Le serveur les reprend pour qu'un
    poste ne voie jamais deux fois la meme perte.
    """

    movement_ids: dict[uuid.UUID, uuid.UUID] = Field(default_factory=dict)


class InventoryLineOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    product_id: uuid.UUID
    theoretical_qty: int
    counted_qty: int | None
    variance: int


class InventoryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    stock_location_id: uuid.UUID
    label: str
    status: InventoryStatus
    inventory_date: dt.date | None
    started_at: dt.datetime | None
    closed_at: dt.datetime | None
    closed_by: uuid.UUID | None
    created_by: uuid.UUID | None
    # Un inventaire abandonne n'est plus ouvert : la tablette l'apprend par
    # cette date, comme toute suppression douce.
    deleted_at: dt.datetime | None
    updated_at: dt.datetime
    lines: list[InventoryLineOut]
