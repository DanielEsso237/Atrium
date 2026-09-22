"""Routes chambres (hebergement)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import Room, User
from app.schemas.rooms import RoomIn, RoomOut

router = APIRouter(prefix="/rooms", tags=["chambres"])


@router.get(
    "",
    response_model=list[RoomOut],
    dependencies=[Depends(require_permission("rooms.read"))],
)
async def list_rooms(session: AsyncSession = Depends(get_session)) -> list[Room]:
    """Plan de l'hotel (cahier des charges, paragraphe 5.2).

    Toutes les chambres actives, triees par numero, avec leur type et leur
    etage deja charges (relations `lazy="joined"` sur le modele) -- pas de
    requete supplementaire par chambre.
    """
    result = await session.execute(
        select(Room)
        .where(Room.deleted_at.is_(None), Room.is_active.is_(True))
        .order_by(Room.number)
    )
    return list(result.scalars().all())


@router.post(
    "",
    response_model=RoomOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_room(
    payload: RoomIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("rooms.write")),
) -> Room:
    """Ajoute une chambre physique (ecran d'administration, hors cahier des
    charges chiffre mais indispensable pour faire evoluer l'inventaire de
    l'hotel sans repasser par une migration).
    """
    room = Room(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(room)
    await session.commit()
    await session.refresh(room, attribute_names=["room_type", "floor"])
    return room
