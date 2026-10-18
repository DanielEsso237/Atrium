"""Les commandes en chambre encore en route : commandees, pas encore livrees.

Une commande en chambre n'ecrit sur l'ardoise qu'a sa livraison. D'ici la,
elle pese quand meme sur ce que le client doit -- le plafond la compte -- et
elle retient le client : on ne le laisse pas partir avec un plateau dans
l'escalier, sans quoi la livraison trouverait son ardoise close et la file du
point de vente se bloquerait derriere.
"""

from __future__ import annotations

import uuid

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Order
from app.models.enums import OrderStatus, OrderType

# Commandee (SENT), prise en charge par le point de vente (IN_PREP).
EN_COURS = (OrderStatus.SENT, OrderStatus.IN_PREP)


def _en_cours(folio_id: uuid.UUID):
    return (
        Order.folio_id == folio_id,
        Order.type == OrderType.ROOM_SERVICE,
        Order.status.in_(EN_COURS),
        Order.deleted_at.is_(None),
    )


async def pending_total(session: AsyncSession, folio_id: uuid.UUID) -> int:
    """Le total des commandes en chambre pas encore livrees sur cette ardoise."""
    total = await session.scalar(
        select(func.coalesce(func.sum(Order.total), 0)).where(*_en_cours(folio_id))
    )
    return int(total or 0)


async def ensure_none_pending(session: AsyncSession, folio_id: uuid.UUID, geste: str) -> None:
    """409 tant qu'une commande en chambre est en route vers ce sejour."""
    combien = await session.scalar(select(func.count()).where(*_en_cours(folio_id)))
    if combien:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"{combien} commande(s) en chambre pas encore livree(s) : "
            f"livrez-les ou annulez-les avant {geste}.",
        )
