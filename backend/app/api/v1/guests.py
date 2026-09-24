"""Routes clients (F1.6 du cahier des charges)."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import Guest, User
from app.schemas.guests import GuestIn, GuestOut
from app.services.numbering import Scope, next_number

router = APIRouter(prefix="/guests", tags=["clients"])


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
        code=await next_number(session, user.hotel_id, Scope.GUEST),
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
