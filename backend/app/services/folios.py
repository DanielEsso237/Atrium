"""Operations partagees sur les folios (facturation, report restaurant).

Les totaux d'un folio (`charges_total`, `payments_total`, `balance`) sont
redondants avec ses lignes : ils existent pour qu'une tablette affiche un solde
sans agreger l'historique. Deux regles les gardent justes :

1. On les **recalcule depuis la base**, jamais par `folio.total += montant` :
   deux paiements simultanes sur le meme folio lisaient la meme valeur de
   depart et l'un des deux disparaissait du total.
2. Toute ecriture verrouille la ligne du folio (`SELECT ... FOR UPDATE`)
   avant de la modifier : les ecritures concurrentes sur un meme folio
   passent l'une apres l'autre, et un folio ne peut pas etre clos pendant
   qu'on y porte une charge.
"""

from __future__ import annotations

import uuid

from fastapi import HTTPException, status
from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Folio, FolioItem, Payment


async def get_folio(
    session: AsyncSession, folio_id: uuid.UUID, hotel_id: uuid.UUID, *, for_update: bool = False
) -> Folio:
    folio = await session.get(Folio, folio_id, with_for_update=for_update)
    if folio is None or folio.hotel_id != hotel_id or folio.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Folio introuvable.")
    return folio


async def recompute_totals(session: AsyncSession, folio: Folio) -> None:
    """Recalcule les trois totaux depuis `folio_items` et `payments`.

    Deux agregats indexes par `folio_id` : quelques lignes par sejour, cout
    negligeable, et le resultat ne depend plus de l'ordre des ecritures.
    """
    charges = await session.scalar(
        select(func.coalesce(func.sum(FolioItem.amount), 0)).where(
            FolioItem.folio_id == folio.id,
            FolioItem.is_void.is_(False),
            FolioItem.deleted_at.is_(None),
        )
    )
    payments = await session.scalar(
        select(
            func.coalesce(
                func.sum(case((Payment.is_refund, -Payment.amount), else_=Payment.amount)), 0
            )
        ).where(Payment.folio_id == folio.id, Payment.deleted_at.is_(None))
    )
    # SUM(bigint) renvoie un numeric (Decimal) : on reste en francs entiers.
    folio.charges_total = int(charges or 0)
    folio.payments_total = int(payments or 0)
    folio.balance = folio.charges_total - folio.payments_total
