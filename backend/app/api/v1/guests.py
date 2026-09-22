"""Routes clients (F1.6 du cahier des charges)."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import Guest, User
from app.schemas.guests import GuestIn, GuestOut

router = APIRouter(prefix="/guests", tags=["clients"])


async def _next_code(session: AsyncSession, hotel_id: uuid.UUID) -> str:
    """Code lisible sequentiel (CLI-000001).

    Base sur un COUNT, pas sur une sequence PostgreSQL dediee : suffisant tant
    que la creation de clients reste a faible concurrence (un seul poste
    reception a la fois sur l'etablissement pilote). A revoir avec une
    sequence par hotel si plusieurs postes creent des clients en parallele.
    """
    count = await session.scalar(
        select(func.count()).select_from(Guest).where(Guest.hotel_id == hotel_id)
    )
    return f"CLI-{(count or 0) + 1:06d}"


@router.get("", response_model=list[GuestOut])
async def list_guests(
    q: str | None = Query(None, description="Recherche nom, telephone ou email"),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("guests.read")),
) -> list[Guest]:
    stmt = select(Guest).where(Guest.hotel_id == user.hotel_id, Guest.deleted_at.is_(None))
    if q:
        like = f"%{q}%"
        stmt = stmt.where(
            or_(
                Guest.first_name.ilike(like),
                Guest.last_name.ilike(like),
                Guest.phone.ilike(like),
                Guest.email.ilike(like),
            )
        )
    stmt = stmt.order_by(Guest.last_name, Guest.first_name)
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.post("", response_model=GuestOut, status_code=status.HTTP_201_CREATED)
async def create_guest(
    payload: GuestIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("guests.write")),
) -> Guest:
    guest = Guest(
        hotel_id=user.hotel_id,
        code=await _next_code(session, user.hotel_id),
        **payload.model_dump(),
    )
    session.add(guest)
    await session.commit()
    await session.refresh(guest)
    return guest


@router.get("/{guest_id}", response_model=GuestOut)
async def get_guest(
    guest_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("guests.read")),
) -> Guest:
    guest = await session.get(Guest, guest_id)
    if guest is None or guest.hotel_id != user.hotel_id or guest.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Client introuvable.")
    return guest


@router.patch("/{guest_id}", response_model=GuestOut)
async def update_guest(
    guest_id: uuid.UUID,
    payload: GuestIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("guests.write")),
) -> Guest:
    guest = await session.get(Guest, guest_id)
    if guest is None or guest.hotel_id != user.hotel_id or guest.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Client introuvable.")
    for field, value in payload.model_dump().items():
        setattr(guest, field, value)
    await session.commit()
    await session.refresh(guest)
    return guest
