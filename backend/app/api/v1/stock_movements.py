"""Routes mouvements de stock et niveaux courants.

Deux regles tiennent tout le fichier.

**Un mouvement arrive de la file d'une tablette.** Il porte son `id`, et un
renvoi du meme id rend le mouvement deja enregistre au lieu de compter deux
fois la meme caisse de bieres.

**Le serveur ne refuse jamais un stock negatif.** Le stock est theorique : une
livraison pas encore saisie, une casse oubliee le font mentir. Refuser une
vente ou un transfert pour autant bloquerait la file d'envoi de la tablette,
avec tout ce qui attend derriere (decision du 8 octobre : on vend, et
l'econome est alerte). C'est la tablette qui previent avant d'envoyer.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.core.ids import uuid7
from app.db.session import get_session
from app.models import StockLevel, StockLocation, StockMovement, User
from app.models.enums import StockMovementStatus, StockMovementType
from app.services.stock_levels import apply_movement
from app.schemas.stock import (
    StockDecisionIn,
    StockLevelOut,
    StockMovementIn,
    StockMovementOut,
)

router = APIRouter(tags=["mouvements de stock"])


async def _magasin(session: AsyncSession, location_id: uuid.UUID, user: User) -> StockLocation:
    location = await session.get(StockLocation, location_id)
    if location is None or location.hotel_id != user.hotel_id or location.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Magasin introuvable.")
    return location


async def _mouvement(session: AsyncSession, movement_id: uuid.UUID, user: User) -> StockMovement:
    m = await session.get(StockMovement, movement_id, with_for_update=True)
    if m is None or m.hotel_id != user.hotel_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Mouvement introuvable.")
    return m


@router.get("/stock-levels", response_model=list[StockLevelOut])
async def list_stock_levels(
    stock_location_id: uuid.UUID | None = None,
    product_id: uuid.UUID | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.read")),
) -> list[StockLevel]:
    stmt = select(StockLevel)
    if stock_location_id:
        stmt = stmt.where(StockLevel.stock_location_id == stock_location_id)
    if product_id:
        stmt = stmt.where(StockLevel.product_id == product_id)
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.get("/stock-movements", response_model=list[StockMovementOut])
async def list_stock_movements(
    product_id: uuid.UUID | None = None,
    stock_location_id: uuid.UUID | None = None,
    status_filter: StockMovementStatus | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.read")),
) -> list[StockMovement]:
    """L'historique ; `status_filter=PENDING` donne les transferts a valider."""
    stmt = select(StockMovement).where(StockMovement.hotel_id == user.hotel_id)
    if product_id:
        stmt = stmt.where(StockMovement.product_id == product_id)
    if stock_location_id:
        stmt = stmt.where(StockMovement.stock_location_id == stock_location_id)
    if status_filter:
        stmt = stmt.where(StockMovement.status == status_filter)
    stmt = stmt.order_by(StockMovement.moved_at.desc().nullslast())
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.post(
    "/stock-movements",
    response_model=StockMovementOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Mouvement deja enregistre (meme id) : etat actuel"}},
)
async def create_stock_movement(
    payload: StockMovementIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.movement")),
) -> StockMovement:
    """Enregistre un mouvement. Un transfert attend sa validation ; les autres
    changent le stock tout de suite."""
    # Rejeu d'abord : un renvoi ne doit ni compter deux fois, ni etre refuse.
    if payload.id is not None:
        existing = await session.get(StockMovement, payload.id)
        if existing is not None:
            if existing.hotel_id != user.hotel_id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Mouvement introuvable.")
            response.status_code = status.HTTP_200_OK
            return existing

    if payload.type == StockMovementType.ADJUSTMENT:
        if payload.quantity == 0:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Un ajustement nul ne change rien.")
    elif payload.quantity <= 0:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "La quantite doit etre positive.")

    await _magasin(session, payload.stock_location_id, user)
    if payload.type == StockMovementType.TRANSFER:
        if payload.counterpart_location_id is None:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                "counterpart_location_id est obligatoire pour un transfert.",
            )
        if payload.counterpart_location_id == payload.stock_location_id:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                "Un transfert va d'un magasin a un autre.",
            )
        await _magasin(session, payload.counterpart_location_id, user)

    fields = payload.model_dump(exclude={"id"})
    movement = StockMovement(
        id=payload.id or uuid7(),
        hotel_id=user.hotel_id,
        moved_by=user.id,
        moved_at=dt.datetime.now(dt.timezone.utc),
        status=(
            StockMovementStatus.PENDING
            if payload.type == StockMovementType.TRANSFER
            else StockMovementStatus.APPROVED
        ),
        **fields,
    )
    session.add(movement)
    if movement.status == StockMovementStatus.APPROVED:
        await apply_movement(session, movement)
    await session.commit()
    await session.refresh(movement)
    return movement


@router.post("/stock-movements/{movement_id}/approve", response_model=StockMovementOut)
async def approve_stock_movement(
    movement_id: uuid.UUID,
    payload: StockDecisionIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.transfer.approve")),
) -> StockMovement:
    """Valide un transfert : c'est maintenant que le stock bouge.

    Une seule validation suffit, du controleur ou du comptable. Rejouee, elle
    rend le transfert deja valide sans rien deplacer une seconde fois.
    """
    m = await _mouvement(session, movement_id, user)
    if m.status == StockMovementStatus.APPROVED:
        return m
    if m.status == StockMovementStatus.REJECTED:
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce transfert a deja ete refuse.")
    await apply_movement(session, m)
    m.status = StockMovementStatus.APPROVED
    m.decided_by = user.id
    m.decided_at = dt.datetime.now(dt.timezone.utc)
    m.decision_note = payload.note
    await session.commit()
    await session.refresh(m)
    return m


@router.post("/stock-movements/{movement_id}/reject", response_model=StockMovementOut)
async def reject_stock_movement(
    movement_id: uuid.UUID,
    payload: StockDecisionIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.transfer.approve")),
) -> StockMovement:
    """Refuse un transfert : rien ne bouge, et le motif reste."""
    m = await _mouvement(session, movement_id, user)
    if m.status == StockMovementStatus.REJECTED:
        return m
    if m.status == StockMovementStatus.APPROVED:
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce transfert a deja ete valide.")
    m.status = StockMovementStatus.REJECTED
    m.decided_by = user.id
    m.decided_at = dt.datetime.now(dt.timezone.utc)
    m.decision_note = payload.note
    await session.commit()
    await session.refresh(m)
    return m
