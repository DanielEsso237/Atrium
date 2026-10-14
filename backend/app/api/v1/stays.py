"""L'arrivee directe : un voyageur sans reservation prend une chambre.

Il se presente, choisit une chambre, pour des nuits ou pour quelques heures,
a un prix convenu au comptoir (demande du 14 octobre). Une seule requete fait
tout : la fiche du client si elle manque, le dossier et sa ligne, l'arrivee,
l'ardoise, et la charge du sejour.

**Le prix est celui du sejour entier**, saisi librement. Il devient une seule
charge -- « Sejour 3 h », « Sejour 2 nuits ». Les nuits d'un sejour en nuits
sont inscrites deja portees : personne ne doit les facturer une seconde fois
une a une. Un sejour en heures n'a pas de nuit du tout.

**Un sejour en heures part a `departure_at`**, instant UTC. Sa
`departure_date` n'est que la borne que le schema exige (le lendemain) : le
plan des chambres et les departs du jour lisent l'heure. Il ne compte pas
dans la disponibilite des nuits -- il sera parti avant le soir.

La route est rejouable : la tablette enregistre l'arrivee hors ligne, avec
ses identifiants, et sa file peut renvoyer le meme envoi.
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.api.v1.billing import _check_credit_limit
from app.api.v1.reservations import (
    _check_in_out,
    _ensure_available,
    _folio_of,
    _lock_room_types,
    _replayed,
)
from app.core.ids import uuid7
from app.db.session import get_session
from app.models import (
    Folio,
    FolioItem,
    Guest,
    Reservation,
    ReservationRoom,
    Room,
    RoomType,
    StayNight,
    User,
)
from app.models.enums import (
    ChargeCategory,
    FolioStatus,
    FolioType,
    OccupancyStatus,
    ReservationSource,
    ReservationStatus,
    StayUnit,
)
from app.schemas.reservations import CheckInOut, WalkInStayIn
from app.services.business_day import current_business_date
from app.services.folios import recompute_totals
from app.services.numbering import Scope, next_number

router = APIRouter(prefix="/stays", tags=["reservations"])


def stay_label(unit: StayUnit, duration: int) -> str:
    """« Sejour 3 h », « Sejour 1 nuit », « Sejour 2 nuits »."""
    if unit == StayUnit.HOURS:
        return f"Séjour {duration} h"
    return f"Séjour {duration} nuit{'s' if duration > 1 else ''}"


def night_rates(price: int, nights: int) -> list[int]:
    """Le prix du sejour reparti sur ses nuits, en francs entiers.

    Le reste de la division va a la premiere nuit : la somme des nuits fait
    toujours exactement le prix saisi.
    """
    base, reste = divmod(price, nights)
    return [base + reste] + [base] * (nights - 1)


async def _known_guest(
    session: AsyncSession, payload: WalkInStayIn, user: User
) -> Guest | None:
    """Le client deja connu de l'hotel, ou None si sa fiche est a creer."""
    guest_id = payload.guest_id or payload.guest.id
    if guest_id is None:
        return None
    guest = await session.get(Guest, guest_id)
    if guest is None:
        if payload.guest_id is not None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Client introuvable.")
        return None
    if guest.hotel_id != user.hotel_id or guest.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Client introuvable.")
    # Une fiche envoyee avec un id deja connu est deja montee par sa propre
    # route : on la prend telle quelle, sans la reecrire.
    return guest


@router.post(
    "/walk-in",
    response_model=CheckInOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Arrivee deja enregistree (meme id) : etat actuel"}},
)
async def walk_in_stay(
    payload: WalkInStayIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.create")),
    # L'arrivee porte le sejour sur l'ardoise : qui peut l'une doit pouvoir
    # l'autre (`tests/test_droits_coherents.py`).
    _: User = Depends(require_permission("folio.write")),
) -> dict:
    """Enregistre l'arrivee d'un client sans reservation, d'un seul geste."""
    # `of=Room` : Room charge son type en jointure externe, et PostgreSQL
    # refuse FOR UPDATE sur le cote optionnel d'une jointure. Le verrou fait
    # aussi passer l'un apres l'autre deux envois du meme sejour.
    room = await session.scalar(
        select(Room)
        .where(
            Room.id == payload.room_id,
            Room.hotel_id == user.hotel_id,
            Room.deleted_at.is_(None),
        )
        .with_for_update(of=Room)
        .execution_options(populate_existing=True)
    )
    # Rejeu avant tout refus : la chambre est occupee, justement par ce
    # sejour. Un 409 bloquerait la file d'envoi de la tablette.
    existing = await _replayed(session, Reservation, payload.id, user)
    if existing is not None:
        await session.refresh(existing, attribute_names=["rooms"])
        line_id = existing.rooms[0].id if existing.rooms else None
        response.status_code = status.HTTP_200_OK
        return _check_in_out(existing, await _folio_of(session, line_id) if line_id else None)

    if room is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Chambre introuvable.")
    if room.is_out_of_order or not room.is_active:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cette chambre est hors service.")
    if room.occupancy_status == OccupancyStatus.OCCUPIED:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Cette chambre est deja occupee par un autre sejour."
        )
    for ident, model in (
        (payload.line_id, ReservationRoom),
        (payload.folio_id, Folio),
        (payload.charge_id, FolioItem),
    ):
        if ident is not None and await session.get(model, ident) is not None:
            raise HTTPException(status.HTTP_409_CONFLICT, "Identifiant deja utilise.")

    room_type = await session.get(RoomType, room.room_type_id)
    now = dt.datetime.now(dt.timezone.utc)
    arrival = await current_business_date(session, user.hotel_id)
    if payload.unit == StayUnit.NIGHTS:
        departure = arrival + dt.timedelta(days=payload.duration)
        departure_at = None
        # Des nuits : la chambre ne doit pas etre promise a une reservation.
        await _lock_room_types(session, [room_type.id])
        await _ensure_available(session, user.hotel_id, room_type, arrival, departure)
        rates = night_rates(payload.price, payload.duration)
        au_tarif = payload.price == room_type.default_rate * payload.duration
    else:
        departure = arrival + dt.timedelta(days=1)
        departure_at = now + dt.timedelta(hours=payload.duration)
        rates = []
        # Aucune categorie n'a de tarif a l'heure : le prix est toujours saisi.
        au_tarif = False

    guest = await _known_guest(session, payload, user)
    folio = Folio(
        id=payload.folio_id or uuid7(),
        hotel_id=user.hotel_id,
        type=FolioType.GUEST,
        status=FolioStatus.OPEN,
        guest_id=guest.id if guest is not None else None,
        opened_at=now,
        charges_total=0,
        payments_total=0,
        balance=0,
    )
    # Le plafond du client vaut ici comme pour toute charge : un client connu
    # ne le contourne pas en arrivant sans reservation. Controle avant la
    # premiere ecriture, comme tous les refus de cette route ; une fiche
    # neuve n'a pas de plafond.
    override_by = None
    if guest is not None:
        override_by = await _check_credit_limit(
            session, folio, payload.price, payload.override_by, user
        )

    if guest is None:
        # Le plafond d'un client se regle dans l'administration, pas ici.
        guest = Guest(
            id=payload.guest.id or uuid7(),
            hotel_id=user.hotel_id,
            code=await next_number(session, user.hotel_id, Scope.GUEST),
            **payload.guest.model_dump(exclude={"id", "credit_limit"}),
        )
        session.add(guest)
        await session.flush()
        folio.guest_id = guest.id
    reservation = Reservation(
        id=payload.id,
        hotel_id=user.hotel_id,
        reference=await next_number(session, user.hotel_id, Scope.RESERVATION),
        guest_id=guest.id,
        source=ReservationSource.WALK_IN,
        status=ReservationStatus.CHECKED_IN,
        arrival_date=arrival,
        departure_date=departure,
        estimated_total=payload.price,
    )
    session.add(reservation)
    await session.flush()

    line = ReservationRoom(
        id=payload.line_id or uuid7(),
        reservation_id=reservation.id,
        room_type_id=room_type.id,
        room_id=room.id,
        arrival_date=arrival,
        departure_date=departure,
        # Le prix d'une nuit, ou du sejour entier quand il se compte en heures.
        nightly_rate=rates[-1] if rates else payload.price,
        status=ReservationStatus.CHECKED_IN,
        checked_in_at=now,
        checked_in_by=user.id,
        is_walk_in=True,
        stay_unit=payload.unit,
        departure_at=departure_at,
        rate_set_by=None if au_tarif else user.id,
    )
    session.add(line)
    try:
        await session.flush()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "Identifiant deja utilise.") from exc
    # Les nuits sont inscrites deja portees : la charge du sejour les couvre
    # toutes, et le registre des nuits est ce qui empeche de les refacturer.
    for offset, rate in enumerate(rates):
        session.add(
            StayNight(
                reservation_room_id=line.id,
                business_date=arrival + dt.timedelta(days=offset),
                room_id=room.id,
                rate=rate,
                is_posted=True,
                posted_at=now,
            )
        )
    room.occupancy_status = OccupancyStatus.OCCUPIED

    folio.number = await next_number(session, user.hotel_id, Scope.FOLIO)
    folio.reservation_room_id = line.id
    session.add(folio)
    await session.flush()
    session.add(
        FolioItem(
            id=payload.charge_id or uuid7(),
            folio_id=folio.id,
            category=ChargeCategory.ROOM,
            label=stay_label(payload.unit, payload.duration),
            quantity=1,
            unit_price=payload.price,
            amount=payload.price,
            tax_amount=0,
            tax_rate=0,
            business_date=arrival,
            source_table="reservation_rooms",
            source_id=line.id,
            posted_by=user.id,
            posted_at=now,
            override_by=override_by,
        )
    )
    await session.flush()
    await recompute_totals(session, folio)
    await session.commit()
    await session.refresh(reservation, attribute_names=["rooms"])
    return _check_in_out(reservation, folio.id)
