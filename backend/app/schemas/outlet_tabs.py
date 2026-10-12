"""Schemas des ardoises du comptoir."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, Field

from app.schemas.billing import PaymentIn


class OutletTabOpenIn(BaseModel):
    """Ouvrir une ardoise au comptoir.

    L'identifiant et le numero viennent de la tablette : l'ardoise s'ouvre
    hors ligne, et le meme envoi rejoue doit retrouver la meme ardoise.
    """

    id: uuid.UUID
    outlet_id: uuid.UUID
    tab_number: int = Field(ge=1, description="« Passage n°3 », par point de vente et par jour")
    guest_id: uuid.UUID | None = Field(
        default=None, description="Le client loge, s'il en est un ; nul : client de passage"
    )


class OutletTabSettleIn(BaseModel):
    """Payer l'ardoise : le total, dans le tiroir du point de vente."""

    payment: PaymentIn


class OutletTabToRoomIn(BaseModel):
    """Porter toute l'ardoise sur la chambre, en un geste."""

    room_folio_id: uuid.UUID = Field(description="L'ardoise ouverte du sejour")
    override_by: uuid.UUID | None = Field(
        default=None,
        description="Responsable (folio.override_limit) qui autorise le depassement du seuil",
    )


class OutletTabCancelIn(BaseModel):
    """Annuler l'ardoise d'un client parti sans payer."""

    reason: str = Field(min_length=3, max_length=255)
