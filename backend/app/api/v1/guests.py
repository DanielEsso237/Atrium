"""Routes clients (F1.6 du cahier des charges)."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import func, literal_column, or_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.core.ids import uuid7
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


@router.post(
    "",
    response_model=GuestOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Fiche deja connue (meme id) : mise a jour"}},
)
async def create_guest(
    payload: GuestIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("guests.write")),
) -> Guest:
    """Cree une fiche client, ou la met a jour si la tablette renvoie le meme id.

    Une tablette qui perd le reseau apres l'envoi ne sait pas si l'ecriture est
    passee et la renvoie : sans upsert, chaque coupure creerait un second
    client. Une seule instruction `INSERT ... ON CONFLICT (id) DO UPDATE`,
    restreinte a l'hotel de l'utilisateur : un id qui appartient a un autre
    etablissement ne met rien a jour et repond 404. 201 a la creation, 200
    sur un renvoi. Le code client (CLI-...) n'est attribue qu'a la creation.
    """
    guest_id = payload.id or uuid7()
    fields = payload.model_dump(exclude={"id"})

    existing = (
        await session.execute(
            select(Guest.hotel_id, Guest.code, Guest.deleted_at).where(Guest.id == guest_id)
        )
    ).first()
    if existing is not None and existing.hotel_id != user.hotel_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Client introuvable.")
    if existing is not None and existing.deleted_at is not None:
        # Renvoi tardif d'une fiche supprimee depuis : la creation a bien eu
        # lieu, on ne la ressuscite pas et on ne bloque pas la file d'envoi.
        response.status_code = status.HTTP_200_OK
        return await session.get(Guest, guest_id)

    code = existing.code if existing else await next_number(session, user.hotel_id, Scope.GUEST)
    stmt = insert(Guest).values(id=guest_id, hotel_id=user.hotel_id, code=code, **fields)
    stmt = stmt.on_conflict_do_update(
        index_elements=["id"],
        set_={**{name: stmt.excluded[name] for name in fields}, "updated_at": func.now()},
        where=(Guest.hotel_id == user.hotel_id) & Guest.deleted_at.is_(None),
    ).returning((literal_column("xmax") == 0).label("inserted"))
    row = (await session.execute(stmt)).first()
    if row is None:
        # Course improbable : l'id a ete pris entre-temps par un autre hotel.
        await session.rollback()
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Client introuvable.")
    await session.commit()

    if not row.inserted:
        response.status_code = status.HTTP_200_OK
    return await session.get(Guest, guest_id, populate_existing=True)


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
    for field, value in payload.model_dump(exclude={"id"}).items():
        setattr(guest, field, value)
    await session.commit()
    await session.refresh(guest)
    return guest
