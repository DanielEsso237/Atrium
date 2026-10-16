"""Schemas des annulations : arrivee, depart, encaissement."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, Field


class UndoIn(BaseModel):
    """Qui autorise l'annulation, et pourquoi.

    `approved_by` est le responsable dont le code a ete saisi sur la tablette
    (permission `operations.undo`) : le serveur verifie qu'il existe, est
    actif et a ce droit, comme pour un depassement de plafond.
    """

    approved_by: uuid.UUID
    reason: str = Field(min_length=1, max_length=255)


class PaymentReverseIn(UndoIn):
    id: uuid.UUID = Field(description="Id du remboursement, genere par la tablette (rejeu)")
