"""Routes reservations : disponibilite, creation, check-in/out, annulation

(F1.1-F1.3 du cahier des charges).
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import Folio, Reservation, ReservationRoom, Room, RoomType, StayNight, User
from app.models.enums import (
    FolioStatus,
    FolioType,
    HousekeepingStatus,
    OccupancyStatus,
    ReservationStatus,
)
from app.schemas.reservations import (
    AvailabilityOut,
    CancelIn,
    CheckInIn,
    ReservationIn,
    ReservationOut,
)

router = APIRouter(prefix="/reservations", tags=["reservations"])

# Statuts qui bloquent effectivement l'inventaire d'un type de chambre pour
# une plage de dates -- annule/no-show/parti liberent la place.
OCCUPYING_STATUSES = (
    ReservationStatus.PENDING,
    ReservationStatus.CONFIRMED,
    ReservationStatus.CHECKED_IN,
)


async def _available_rooms(
    session: AsyncSession,
    hotel_id: uuid.UUID,
    room_type_id: uuid.UUID,
    arrival: dt.date,
    departure: dt.date,
) -> tuple[int, int]:
    """Retourne (total, reserve) pour un type de chambre sur une plage de dates.

    Chevauchement classique : deux sejours se croisent des que l'un commence
    avant que l'autre ne finisse, dans les deux sens.
    """
    total = await session.scalar(
        select(func.count())
        .select_from(Room)
        .where(
            Room.hotel_id == hotel_id,
            Room.room_type_id == room_type_id,
            Room.is_active.is_(True),
            Room.deleted_at.is_(None),
        )
    )
    booked = await session.scalar(
        select(func.count())
        .select_from(ReservationRoom)
        .join(Reservation, Reservation.id == ReservationRoom.reservation_id)
        .where(
            Reservation.hotel_id == hotel_id,
            ReservationRoom.room_type_id == room_type_id,
            ReservationRoom.status.in_(OCCUPYING_STATUSES),
            ReservationRoom.arrival_date < departure,
            ReservationRoom.departure_date > arrival,
        )
    )
    return total or 0, booked or 0


async def _next_reference(session: AsyncSession, hotel_id: uuid.UUID) -> str:
    """Meme logique et meme reserve que `_next_code` du domaine clients

    (voir app/api/v1/guests.py) : suffisant pour un seul poste de reception a
    la fois, a revoir avec une sequence PostgreSQL si la concurrence augmente.
    """
    count = await session.scalar(
        select(func.count()).select_from(Reservation).where(Reservation.hotel_id == hotel_id)
    )
    return f"RES-{(count or 0) + 1:06d}"


async def _next_folio_number(session: AsyncSession, hotel_id: uuid.UUID) -> str:
    """Reference interne du folio, pas un numero legal -- voir le commentaire

    de `_next_reference` juste au-dessus ; la vraie sequence sans-trou vit
    dans app/api/v1/billing.py, pour la numerotation des factures.
    """
    count = await session.scalar(
        select(func.count()).select_from(Folio).where(Folio.hotel_id == hotel_id)
    )
    return f"FOL-{(count or 0) + 1:06d}"


async def _get_reservation(
    session: AsyncSession, reservation_id: uuid.UUID, user: User
) -> Reservation:
    reservation = await session.get(Reservation, reservation_id)
    if (
        reservation is None
        or reservation.hotel_id != user.hotel_id
        or reservation.deleted_at is not None
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Reservation introuvable.")
    return reservation


@router.get("", response_model=list[ReservationOut])
async def list_reservations(
    status_filter: ReservationStatus | None = Query(None, alias="status"),
    arrival_from: dt.date | None = None,
    arrival_to: dt.date | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.read")),
) -> list[Reservation]:
    stmt = select(Reservation).where(
        Reservation.hotel_id == user.hotel_id, Reservation.deleted_at.is_(None)
    )
    if status_filter:
        stmt = stmt.where(Reservation.status == status_filter)
    if arrival_from:
        stmt = stmt.where(Reservation.arrival_date >= arrival_from)
    if arrival_to:
        stmt = stmt.where(Reservation.arrival_date <= arrival_to)
    stmt = stmt.order_by(Reservation.arrival_date)
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.get("/availability", response_model=AvailabilityOut)
async def check_availability(
    room_type_id: uuid.UUID,
    arrival_date: dt.date,
    departure_date: dt.date,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.read")),
) -> AvailabilityOut:
    if departure_date <= arrival_date:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "La date de depart doit etre posterieure a la date d'arrivee.",
        )
    total, booked = await _available_rooms(
        session, user.hotel_id, room_type_id, arrival_date, departure_date
    )
    return AvailabilityOut(
        room_type_id=room_type_id,
        arrival_date=arrival_date,
        departure_date=departure_date,
        total_rooms=total,
        booked_rooms=booked,
        available_rooms=max(total - booked, 0),
    )


@router.post("", response_model=ReservationOut, status_code=status.HTTP_201_CREATED)
async def create_reservation(
    payload: ReservationIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.create")),
) -> Reservation:
    # On verifie la disponibilite de chaque ligne AVANT d'ecrire quoi que ce
    # soit : un dossier a moitie cree parce que la 2e chambre sur 3 etait
    # complete serait pire qu'un refus net.
    for line in payload.rooms:
        total, booked = await _available_rooms(
            session, user.hotel_id, line.room_type_id, line.arrival_date, line.departure_date
        )
        if booked >= total:
            room_type = await session.get(RoomType, line.room_type_id)
            label = room_type.label if room_type else str(line.room_type_id)
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"Plus de disponibilite pour '{label}' du {line.arrival_date} au {line.departure_date}.",
            )

    arrival = min(line.arrival_date for line in payload.rooms)
    departure = max(line.departure_date for line in payload.rooms)

    reservation = Reservation(
        hotel_id=user.hotel_id,
        reference=await _next_reference(session, user.hotel_id),
        guest_id=payload.guest_id,
        source=payload.source,
        status=ReservationStatus.CONFIRMED,
        arrival_date=arrival,
        departure_date=departure,
        adults=payload.adults,
        children=payload.children,
        special_requests=payload.special_requests,
        internal_notes=payload.internal_notes,
    )
    session.add(reservation)
    await session.flush()  # pour obtenir reservation.id avant d'ajouter les lignes

    total_amount = 0
    for line in payload.rooms:
        room_type = await session.get(RoomType, line.room_type_id)
        if room_type is None or room_type.hotel_id != user.hotel_id:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, "Type de chambre invalide."
            )
        rate = line.nightly_rate if line.nightly_rate is not None else room_type.default_rate

        res_room = ReservationRoom(
            reservation_id=reservation.id,
            room_type_id=line.room_type_id,
            arrival_date=line.arrival_date,
            departure_date=line.departure_date,
            adults=line.adults,
            children=line.children,
            nightly_rate=rate,
            status=ReservationStatus.CONFIRMED,
        )
        session.add(res_room)
        await session.flush()

        # Une ligne stay_nights par nuit : c'est elle que la cloture
        # journaliere postera au folio plus tard (voir le modele StayNight).
        current = line.arrival_date
        while current < line.departure_date:
            session.add(
                StayNight(reservation_room_id=res_room.id, business_date=current, rate=rate)
            )
            total_amount += rate
            current += dt.timedelta(days=1)

    reservation.estimated_total = total_amount
    await session.commit()
    await session.refresh(reservation, attribute_names=["rooms"])
    return reservation


@router.get("/{reservation_id}", response_model=ReservationOut)
async def get_reservation(
    reservation_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.read")),
) -> Reservation:
    return await _get_reservation(session, reservation_id, user)


@router.post("/{reservation_id}/rooms/{room_line_id}/check-in", response_model=ReservationOut)
async def check_in(
    reservation_id: uuid.UUID,
    room_line_id: uuid.UUID,
    payload: CheckInIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.manage")),
) -> Reservation:
    """F1.2 -- attribution de la chambre physique si elle n'a pas deja ete

    faite, puis bascule de la chambre en occupee (voir docs/01, "trois axes
    d'etat" : ce champ est independant du statut menage).
    """
    reservation = await _get_reservation(session, reservation_id, user)
    line = next((r for r in reservation.rooms if r.id == room_line_id), None)
    if line is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ligne de reservation introuvable.")
    if line.status not in (ReservationStatus.PENDING, ReservationStatus.CONFIRMED):
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Impossible d'enregistrer l'arrivee (statut actuel : {line.status}).",
        )

    room_id = payload.room_id or line.room_id
    if room_id is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "Aucune chambre assignee : precise room_id."
        )

    room = await session.get(Room, room_id)
    if room is None or room.hotel_id != user.hotel_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Chambre introuvable.")
    if room.room_type_id != line.room_type_id:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "Cette chambre n'appartient pas a la categorie reservee.",
        )
    if room.is_out_of_order:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cette chambre est hors service.")
    if room.occupancy_status == OccupancyStatus.OCCUPIED:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Cette chambre est deja occupee par un autre sejour."
        )

    line.room_id = room_id
    line.status = ReservationStatus.CHECKED_IN
    line.checked_in_at = dt.datetime.now(dt.timezone.utc)
    line.checked_in_by = user.id
    if payload.key_card_code:
        line.key_card_code = payload.key_card_code

    room.occupancy_status = OccupancyStatus.OCCUPIED

    # Le folio est le pivot de toute la facturation (F1.4) : il nait au
    # check-in, pas a la reservation, puisque c'est l'arrivee qui engage
    # reellement le sejour. On n'en cree pas un deuxieme si l'appelant relance
    # le check-in apres une erreur reseau, par exemple.
    existing_folio = await session.scalar(
        select(Folio).where(Folio.reservation_room_id == line.id, Folio.deleted_at.is_(None))
    )
    if existing_folio is None:
        session.add(
            Folio(
                hotel_id=user.hotel_id,
                number=await _next_folio_number(session, user.hotel_id),
                type=FolioType.GUEST,
                status=FolioStatus.OPEN,
                reservation_room_id=line.id,
                guest_id=reservation.guest_id,
                opened_at=dt.datetime.now(dt.timezone.utc),
            )
        )

    await session.commit()
    await session.refresh(reservation, attribute_names=["rooms"])
    return reservation


@router.post("/{reservation_id}/rooms/{room_line_id}/check-out", response_model=ReservationOut)
async def check_out(
    reservation_id: uuid.UUID,
    room_line_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.manage")),
) -> Reservation:
    """F1.3 -- la chambre redevient vacante mais sale : le menage est un

    evenement a part (voir housekeeping, a venir), pas une consequence
    automatique du depart.
    """
    reservation = await _get_reservation(session, reservation_id, user)
    line = next((r for r in reservation.rooms if r.id == room_line_id), None)
    if line is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ligne de reservation introuvable.")
    if line.status != ReservationStatus.CHECKED_IN:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Impossible d'enregistrer le depart (statut actuel : {line.status}).",
        )

    line.status = ReservationStatus.CHECKED_OUT
    line.checked_out_at = dt.datetime.now(dt.timezone.utc)
    line.checked_out_by = user.id

    if line.room_id:
        room = await session.get(Room, line.room_id)
        if room is not None:
            room.occupancy_status = OccupancyStatus.VACANT
            room.housekeeping_status = HousekeepingStatus.DIRTY

    await session.commit()
    await session.refresh(reservation, attribute_names=["rooms"])
    return reservation


@router.post("/{reservation_id}/cancel", response_model=ReservationOut)
async def cancel_reservation(
    reservation_id: uuid.UUID,
    payload: CancelIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.manage")),
) -> Reservation:
    reservation = await _get_reservation(session, reservation_id, user)
    if any(r.status == ReservationStatus.CHECKED_IN for r in reservation.rooms):
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "Au moins une chambre est deja enregistree (arrivee effectuee) : "
            "impossible d'annuler tout le dossier.",
        )

    reservation.status = ReservationStatus.CANCELLED
    reservation.cancelled_at = dt.datetime.now(dt.timezone.utc)
    reservation.cancel_reason = payload.reason
    for line in reservation.rooms:
        if line.status != ReservationStatus.CHECKED_OUT:
            line.status = ReservationStatus.CANCELLED

    await session.commit()
    await session.refresh(reservation, attribute_names=["rooms"])
    return reservation
