"""Routes parametrage de l'etablissement (paragraphe 6.5 -- ecran d'admin)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user, require_permission
from app.db.session import get_session
from app.models import Hotel, User
from app.schemas.hotel import HotelOut, HotelUpdate

router = APIRouter(prefix="/hotel", tags=["etablissement"])


@router.get("", response_model=HotelOut)
async def get_hotel(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> Hotel:
    """Lecture ouverte a tout utilisateur connecte : l'heure de bascule du

    jour hotelier (`day_rollover_hour`) sert de reference a tous les postes,
    pas seulement a l'administration.
    """
    hotel = await session.get(Hotel, user.hotel_id)
    if hotel is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Etablissement introuvable.")
    return hotel


@router.patch("", response_model=HotelOut)
async def update_hotel(
    payload: HotelUpdate,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("hotel.write")),
) -> Hotel:
    hotel = await session.get(Hotel, user.hotel_id)
    if hotel is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Etablissement introuvable.")
    for field, value in payload.model_dump().items():
        setattr(hotel, field, value)
    await session.commit()
    await session.refresh(hotel)
    return hotel
