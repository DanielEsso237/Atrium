"""Routes mouvements de stock et niveaux courants."""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import StockLevel, StockMovement, User
from app.models.enums import StockMovementType
from app.schemas.stock import StockLevelOut, StockMovementIn, StockMovementOut

router = APIRouter(tags=["mouvements de stock"])


async def _apply_delta(
    session: AsyncSession, product_id: uuid.UUID, location_id: uuid.UUID, delta: int
) -> None:
    """Met a jour le compteur `stock_levels`. Refuse ce qui ferait passer

    une quantite sous zero -- `stock_movements` reste la source de verite
    (voir le modele), mais un mouvement qui viderait un magasin en negatif
    signale une erreur de saisie, pas un etat valide.
    """
    level = await session.scalar(
        select(StockLevel).where(
            StockLevel.product_id == product_id, StockLevel.stock_location_id == location_id
        )
    )
    current = level.quantity if level else 0
    new_qty = current + delta
    if new_qty < 0:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Stock insuffisant (disponible : {current}, demande : {-delta}).",
        )
    now = dt.datetime.now(dt.timezone.utc)
    if level is None:
        session.add(
            StockLevel(
                product_id=product_id,
                stock_location_id=location_id,
                quantity=new_qty,
                last_movement_at=now,
            )
        )
    else:
        level.quantity = new_qty
        level.last_movement_at = now


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
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.read")),
) -> list[StockMovement]:
    stmt = select(StockMovement).where(StockMovement.hotel_id == user.hotel_id)
    if product_id:
        stmt = stmt.where(StockMovement.product_id == product_id)
    if stock_location_id:
        stmt = stmt.where(StockMovement.stock_location_id == stock_location_id)
    stmt = stmt.order_by(StockMovement.moved_at.desc().nullslast())
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.post(
    "/stock-movements", response_model=StockMovementOut, status_code=status.HTTP_201_CREATED
)
async def create_stock_movement(
    payload: StockMovementIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.movement")),
) -> StockMovement:
    if payload.type == StockMovementType.TRANSFER:
        if payload.counterpart_location_id is None:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                "counterpart_location_id est obligatoire pour un transfert.",
            )
        if payload.quantity <= 0:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "La quantite doit etre positive.")
        await _apply_delta(session, payload.product_id, payload.stock_location_id, -payload.quantity)
        await _apply_delta(
            session, payload.product_id, payload.counterpart_location_id, payload.quantity
        )
    elif payload.type == StockMovementType.ADJUSTMENT:
        await _apply_delta(session, payload.product_id, payload.stock_location_id, payload.quantity)
    elif payload.type in (StockMovementType.IN, StockMovementType.RETURN):
        if payload.quantity <= 0:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "La quantite doit etre positive.")
        await _apply_delta(session, payload.product_id, payload.stock_location_id, payload.quantity)
    else:  # OUT, LOSS
        if payload.quantity <= 0:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "La quantite doit etre positive.")
        await _apply_delta(session, payload.product_id, payload.stock_location_id, -payload.quantity)

    movement = StockMovement(
        hotel_id=user.hotel_id,
        moved_by=user.id,
        moved_at=dt.datetime.now(dt.timezone.utc),
        **payload.model_dump(),
    )
    session.add(movement)
    await session.commit()
    await session.refresh(movement)
    return movement
