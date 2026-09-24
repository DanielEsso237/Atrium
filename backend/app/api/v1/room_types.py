"""Routes types de chambres (referentiel, ecran d'administration)."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import RoomType, User
from app.schemas.room_types import RoomTypeIn, RoomTypeOut

router = APIRouter(prefix="/room-types", tags=["types de chambres"])


@router.get(
    "",
    response_model=list[RoomTypeOut],
)
async def list_room_types(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("room_types.read")),
) -> list[RoomType]:
    result = await session.execute(
        select(RoomType)
        .where(
            RoomType.hotel_id == user.hotel_id,
            RoomType.deleted_at.is_(None),
        )
        .order_by(RoomType.sort_order, RoomType.label)
    )
    return list(result.scalars().all())

@router.post(
    "",
    response_model=RoomTypeOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_room_type(
    payload: RoomTypeIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("room_types.write")),
) -> RoomType:
    room_type = RoomType(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(room_type)
    await session.commit()
    await session.refresh(room_type)
    return room_type


@router.patch(
    "/{room_type_id}",
    response_model=RoomTypeOut,
)
async def update_room_type(
    room_type_id: uuid.UUID,
    payload: RoomTypeIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("room_types.write")),
) -> RoomType:
    """Revalorisation tarifaire : une seule ecriture met a jour toutes les
    chambres de la categorie, puisque le tarif est porte par le type et non
    par la chambre (voir docs/01-modele-de-donnees.md).
    """
    room_type = await session.get(RoomType, room_type_id)
    if (
        room_type is None
        or room_type.hotel_id != user.hotel_id
        or room_type.deleted_at is not None
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Type de chambre introuvable.")
    for field, value in payload.model_dump().items():
        setattr(room_type, field, value)
    await session.commit()
    await session.refresh(room_type)
    return room_type
