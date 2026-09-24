"""Routes reservations : disponibilite, creation, modification, calendrier,

check-in/out, annulation (F1.1-F1.3 du cahier des charges).
"""

from __future__ import annotations

import datetime as dt
import uuid
from collections.abc import Iterable, Mapping, Sequence

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import Folio, Guest, Reservation, ReservationRoom, Room, RoomType, StayNight, User
from app.models.enums import (
    FolioStatus,
    FolioType,
    HousekeepingStatus,
    OccupancyStatus,
    ReservationStatus,
)
from app.schemas.reservations import (
    AvailabilityOut,
    CalendarCell,
    CalendarOut,
    CalendarUnassigned,
    CancelIn,
    CheckInIn,
    ReservationIn,
    ReservationOut,
    ReservationUpdate,
)
from app.services.numbering import Scope, next_number

router = APIRouter(prefix="/reservations", tags=["reservations"])

# Statuts qui bloquent effectivement l'inventaire d'un type de chambre pour
# une plage de dates -- annule/no-show/parti liberent la place.
OCCUPYING_STATUSES = (
    ReservationStatus.PENDING,
    ReservationStatus.CONFIRMED,
    ReservationStatus.CHECKED_IN,
)
# Une ligne encore modifiable : le client n'est pas arrive.
EDITABLE_LINE_STATUSES = (ReservationStatus.PENDING, ReservationStatus.CONFIRMED)
# Ce que le calendrier affiche : les sejours passes restent visibles.
CALENDAR_STATUSES = (*OCCUPYING_STATUSES, ReservationStatus.CHECKED_OUT)
CALENDAR_MAX_DAYS = 92


async def _lock_room_types(session: AsyncSession, room_type_ids: Iterable[uuid.UUID]) -> None:
    """Serialise les reservations concurrentes sur un meme type de chambre.

    Sans verrou, deux receptions qui reservent la derniere chambre en meme
    temps voient toutes deux "1 disponible" et surreservent. Un verrou
    consultatif transactionnel par type suffit : il ne bloque que les
    reservations du meme type, se libere seul au commit/rollback, et ne touche
    aucune table. Pris dans un ordre fixe pour exclure tout interblocage.
    """
    for room_type_id in sorted(set(room_type_ids)):
        await session.execute(
            select(func.pg_advisory_xact_lock(func.hashtextextended(str(room_type_id), 0)))
        )


async def _available_rooms(
    session: AsyncSession,
    hotel_id: uuid.UUID,
    room_type_id: uuid.UUID,
    arrival: dt.date,
    departure: dt.date,
    *,
    exclude_line_id: uuid.UUID | None = None,
) -> tuple[int, int]:
    """Retourne (total, reserve) pour un type de chambre sur une plage de dates.

    Chevauchement classique : deux sejours se croisent des que l'un commence
    avant que l'autre ne finisse, dans les deux sens. `exclude_line_id` sert a
    la modification : une ligne ne se bloque pas elle-meme.
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
    booked_stmt = (
        select(func.count())
        .select_from(ReservationRoom)
        .join(Reservation, Reservation.id == ReservationRoom.reservation_id)
        .where(
            Reservation.hotel_id == hotel_id,
            ReservationRoom.room_type_id == room_type_id,
            ReservationRoom.deleted_at.is_(None),
            ReservationRoom.status.in_(OCCUPYING_STATUSES),
            ReservationRoom.arrival_date < departure,
            ReservationRoom.departure_date > arrival,
        )
    )
    if exclude_line_id is not None:
        booked_stmt = booked_stmt.where(ReservationRoom.id != exclude_line_id)
    booked = await session.scalar(booked_stmt)
    return total or 0, booked or 0


async def _ensure_available(
    session: AsyncSession,
    hotel_id: uuid.UUID,
    room_type: RoomType,
    arrival: dt.date,
    departure: dt.date,
    *,
    exclude_line_id: uuid.UUID | None = None,
) -> None:
    total, booked = await _available_rooms(
        session, hotel_id, room_type.id, arrival, departure, exclude_line_id=exclude_line_id
    )
    if booked >= total:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Plus de disponibilite pour '{room_type.label}' du {arrival} au {departure}.",
        )


async def _room_types_by_id(
    session: AsyncSession, hotel_id: uuid.UUID, ids: Iterable[uuid.UUID]
) -> dict[uuid.UUID, RoomType]:
    """Charge et valide en une requete tous les types de chambre demandes."""
    wanted = set(ids)
    result = await session.execute(
        select(RoomType).where(
            RoomType.id.in_(wanted), RoomType.hotel_id == hotel_id, RoomType.deleted_at.is_(None)
        )
    )
    found = {rt.id: rt for rt in result.scalars().all()}
    if wanted - found.keys():
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Type de chambre invalide.")
    return found


def _sync_stay_nights(
    session: AsyncSession, line: ReservationRoom, existing: Sequence[StayNight], rate: int
) -> int:
    """Aligne les `stay_nights` de la ligne sur ses dates ; renvoie le total.

    Une ligne par nuit : c'est elle que la cloture journaliere postera au
    folio (voir le modele StayNight). Les nuits sorties de la plage sont
    supprimees logiquement (une suppression physique serait invisible aux
    tablettes) et une nuit qui revient dans la plage est reprise telle quelle,
    ce qui respecte l'unicite (reservation_room_id, business_date).
    """
    by_date = {night.business_date: night for night in existing}
    now = dt.datetime.now(dt.timezone.utc)
    wanted: set[dt.date] = set()
    total = 0
    current = line.arrival_date
    while current < line.departure_date:
        wanted.add(current)
        night = by_date.get(current)
        if night is None:
            session.add(
                StayNight(reservation_room_id=line.id, business_date=current, rate=rate)
            )
        else:
            night.deleted_at = None
            night.rate = rate
        total += rate
        current += dt.timedelta(days=1)

    for date, night in by_date.items():
        if date not in wanted and night.deleted_at is None:
            night.deleted_at = now
    return total


def _active_lines(reservation: Reservation) -> list[ReservationRoom]:
    return [
        r
        for r in reservation.rooms
        if r.deleted_at is None
        and r.status not in (ReservationStatus.CANCELLED, ReservationStatus.NO_SHOW)
    ]


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


def build_calendar(
    rooms: Sequence[Mapping],
    lines: Sequence[Mapping],
    date_from: dt.date,
    date_to: dt.date,
) -> tuple[list[CalendarCell], list[CalendarUnassigned]]:
    """Assemble la grille chambre x jour (bornes incluses). Pure, testee sans base.

    `rooms` : {id, number}. `lines` : lignes de reservation qui chevauchent la
    periode, avec {reservation_room_id, reservation_id, room_id, room_type_id,
    arrival_date, departure_date, status, reference, guest_name}. Une ligne
    sans `room_id` n'a pas de case : elle part dans `unassigned`.
    """
    occupied: dict[tuple[uuid.UUID, dt.date], Mapping] = {}
    unassigned: list[CalendarUnassigned] = []
    for line in lines:
        if line["room_id"] is None:
            unassigned.append(
                CalendarUnassigned(
                    reservation_room_id=line["reservation_room_id"],
                    reservation_id=line["reservation_id"],
                    reference=line["reference"],
                    guest_name=line["guest_name"],
                    room_type_id=line["room_type_id"],
                    arrival_date=line["arrival_date"],
                    departure_date=line["departure_date"],
                    status=line["status"],
                )
            )
            continue
        day = max(line["arrival_date"], date_from)
        last = min(line["departure_date"] - dt.timedelta(days=1), date_to)
        while day <= last:
            # Un sejour en cours prime sur une ligne deja partie le meme jour.
            key = (line["room_id"], day)
            if key not in occupied or line["status"] != ReservationStatus.CHECKED_OUT:
                occupied[key] = line
            day += dt.timedelta(days=1)

    rows: list[CalendarCell] = []
    days = [date_from + dt.timedelta(days=i) for i in range((date_to - date_from).days + 1)]
    for room in rooms:
        for day in days:
            line = occupied.get((room["id"], day))
            cell = CalendarCell(room_id=room["id"], room_number=room["number"], date=day)
            if line is not None:
                cell.reservation_room_id = line["reservation_room_id"]
                cell.reservation_id = line["reservation_id"]
                cell.reference = line["reference"]
                cell.guest_name = line["guest_name"]
                cell.status = line["status"]
            rows.append(cell)
    return rows, unassigned


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


@router.get("/calendar", response_model=CalendarOut)
async def reservation_calendar(
    date_from: dt.date = Query(alias="from"),
    date_to: dt.date = Query(alias="to"),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.read")),
) -> CalendarOut:
    """F1.1 -- planning : une ligne par chambre et par jour, bornes incluses.

    Deux requetes quelle que soit la periode (chambres, puis sejours qui la
    chevauchent), la grille est assemblee en memoire. Les lignes sans chambre
    attribuee -- le cas normal avant le jour d'arrivee -- sont renvoyees a part
    dans `unassigned`, sinon le planning paraitrait vide.
    """
    if date_to < date_from:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "`to` doit etre posterieur ou egal a `from`."
        )
    if (date_to - date_from).days + 1 > CALENDAR_MAX_DAYS:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"Periode limitee a {CALENDAR_MAX_DAYS} jours.",
        )

    rooms = (
        await session.execute(
            select(Room.id, Room.number)
            .where(
                Room.hotel_id == user.hotel_id,
                Room.deleted_at.is_(None),
                Room.is_active.is_(True),
            )
            .order_by(Room.number)
        )
    ).mappings().all()

    lines = (
        await session.execute(
            select(
                ReservationRoom.id.label("reservation_room_id"),
                ReservationRoom.reservation_id,
                ReservationRoom.room_id,
                ReservationRoom.room_type_id,
                ReservationRoom.arrival_date,
                ReservationRoom.departure_date,
                ReservationRoom.status,
                Reservation.reference,
                func.concat_ws(" ", Guest.first_name, Guest.last_name).label("guest_name"),
            )
            .join(Reservation, Reservation.id == ReservationRoom.reservation_id)
            .join(Guest, Guest.id == Reservation.guest_id)
            .where(
                Reservation.hotel_id == user.hotel_id,
                Reservation.deleted_at.is_(None),
                ReservationRoom.deleted_at.is_(None),
                ReservationRoom.status.in_(CALENDAR_STATUSES),
                ReservationRoom.arrival_date <= date_to,
                ReservationRoom.departure_date > date_from,
            )
            .order_by(ReservationRoom.arrival_date)
        )
    ).mappings().all()

    rows, unassigned = build_calendar(rooms, lines, date_from, date_to)
    return CalendarOut(date_from=date_from, date_to=date_to, rows=rows, unassigned=unassigned)


@router.post("", response_model=ReservationOut, status_code=status.HTTP_201_CREATED)
async def create_reservation(
    payload: ReservationIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.create")),
) -> Reservation:
    room_types = await _room_types_by_id(
        session, user.hotel_id, (line.room_type_id for line in payload.rooms)
    )
    await _lock_room_types(session, room_types)

    # On verifie la disponibilite de chaque ligne AVANT d'ecrire quoi que ce
    # soit : un dossier a moitie cree parce que la 2e chambre sur 3 etait
    # complete serait pire qu'un refus net. Le verrou pris juste au-dessus
    # garantit que la reponse reste vraie jusqu'au commit.
    for line in payload.rooms:
        await _ensure_available(
            session,
            user.hotel_id,
            room_types[line.room_type_id],
            line.arrival_date,
            line.departure_date,
        )

    reservation = Reservation(
        hotel_id=user.hotel_id,
        reference=await next_number(session, user.hotel_id, Scope.RESERVATION),
        guest_id=payload.guest_id,
        source=payload.source,
        status=ReservationStatus.CONFIRMED,
        arrival_date=min(line.arrival_date for line in payload.rooms),
        departure_date=max(line.departure_date for line in payload.rooms),
        adults=payload.adults,
        children=payload.children,
        special_requests=payload.special_requests,
        internal_notes=payload.internal_notes,
    )
    session.add(reservation)
    await session.flush()  # pour obtenir reservation.id avant d'ajouter les lignes

    total_amount = 0
    for line in payload.rooms:
        rate = (
            line.nightly_rate
            if line.nightly_rate is not None
            else room_types[line.room_type_id].default_rate
        )
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
        total_amount += _sync_stay_nights(session, res_room, (), rate)

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


@router.patch("/{reservation_id}", response_model=ReservationOut)
async def update_reservation(
    reservation_id: uuid.UUID,
    payload: ReservationUpdate,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.create")),
) -> Reservation:
    """F1.1 -- modification : dates, nombre de personnes, type de chambre.

    L'entete (personnes, demandes, notes) reste modifiable tant que le dossier
    n'est pas annule. Une ligne, elle, n'est modifiable qu'avant l'arrivee :
    une fois le sejour pris en charge, ses dates vivent dans le folio et le
    check-out, plus ici. Tout est controle avant la premiere ecriture, comme a
    la creation.
    """
    reservation = await _get_reservation(session, reservation_id, user)
    if reservation.status in (ReservationStatus.CANCELLED, ReservationStatus.NO_SHOW):
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Dossier non modifiable (statut actuel : {reservation.status}).",
        )

    # `null` explicite : efface un texte libre, ignore pour un champ obligatoire.
    header = payload.model_dump(exclude_unset=True, exclude={"rooms"})
    for field, value in header.items():
        if value is not None or field in ("special_requests", "internal_notes"):
            setattr(reservation, field, value)

    lines_by_id = {line.id: line for line in reservation.rooms if line.deleted_at is None}
    changes = []
    for change in payload.rooms:
        line = lines_by_id.get(change.id)
        if line is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Ligne de reservation introuvable.")
        if line.status not in EDITABLE_LINE_STATUSES:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"Sejour deja pris en charge ou clos (statut : {line.status}) : "
                "modification impossible.",
            )
        fields = {
            k: v
            for k, v in change.model_dump(exclude_unset=True, exclude={"id"}).items()
            if v is not None
        }
        arrival = fields.get("arrival_date", line.arrival_date)
        departure = fields.get("departure_date", line.departure_date)
        if departure <= arrival:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                "La date de depart doit etre posterieure a la date d'arrivee.",
            )
        changes.append((line, fields, arrival, departure))

    if changes:
        room_types = await _room_types_by_id(
            session,
            user.hotel_id,
            (fields.get("room_type_id", line.room_type_id) for line, fields, _, _ in changes),
        )
        await _lock_room_types(session, room_types)
        for line, fields, arrival, departure in changes:
            room_type = room_types[fields.get("room_type_id", line.room_type_id)]
            await _ensure_available(
                session, user.hotel_id, room_type, arrival, departure, exclude_line_id=line.id
            )

        for line, fields, arrival, departure in changes:
            type_changed = fields.get("room_type_id", line.room_type_id) != line.room_type_id
            if type_changed:
                line.room_type_id = fields["room_type_id"]
                # La chambre deja attribuee n'est plus de la bonne categorie.
                line.room_id = None
            line.arrival_date = arrival
            line.departure_date = departure
            line.adults = fields.get("adults", line.adults)
            line.children = fields.get("children", line.children)
            if "nightly_rate" in fields:
                line.nightly_rate = fields["nightly_rate"]
            elif type_changed:
                line.nightly_rate = room_types[line.room_type_id].default_rate

            existing = (
                await session.execute(
                    select(StayNight).where(StayNight.reservation_room_id == line.id)
                )
            ).scalars().all()
            _sync_stay_nights(session, line, existing, line.nightly_rate)

        active = _active_lines(reservation)
        reservation.arrival_date = min(line.arrival_date for line in active)
        reservation.departure_date = max(line.departure_date for line in active)
        reservation.estimated_total = sum(
            line.nightly_rate * (line.departure_date - line.arrival_date).days for line in active
        )

    await session.commit()
    await session.refresh(reservation, attribute_names=["rooms"])
    return reservation


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

    La ligne et la chambre sont verrouillees (`FOR UPDATE`) : deux tablettes
    qui installent deux clients dans la meme chambre au meme moment passent
    l'une apres l'autre, et la seconde voit la chambre occupee.
    """
    reservation = await _get_reservation(session, reservation_id, user)
    line = await session.scalar(
        select(ReservationRoom)
        .where(
            ReservationRoom.id == room_line_id,
            ReservationRoom.reservation_id == reservation.id,
            ReservationRoom.deleted_at.is_(None),
        )
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if line is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ligne de reservation introuvable.")
    if line.status not in EDITABLE_LINE_STATUSES:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Impossible d'enregistrer l'arrivee (statut actuel : {line.status}).",
        )

    room_id = payload.room_id or line.room_id
    if room_id is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "Aucune chambre assignee : precise room_id."
        )

    # `of=Room` : Room charge son type et son etage en jointure externe, et
    # PostgreSQL refuse FOR UPDATE sur le cote optionnel d'une jointure.
    room = await session.scalar(
        select(Room)
        .where(Room.id == room_id, Room.hotel_id == user.hotel_id, Room.deleted_at.is_(None))
        .with_for_update(of=Room)
        .execution_options(populate_existing=True)
    )
    if room is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Chambre introuvable.")
    if room.room_type_id != line.room_type_id:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "Cette chambre n'appartient pas a la categorie reservee.",
        )
    if room.is_out_of_order or not room.is_active:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cette chambre est hors service.")
    if room.occupancy_status == OccupancyStatus.OCCUPIED:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Cette chambre est deja occupee par un autre sejour."
        )

    now = dt.datetime.now(dt.timezone.utc)
    line.room_id = room_id
    line.status = ReservationStatus.CHECKED_IN
    line.checked_in_at = now
    line.checked_in_by = user.id
    if payload.key_card_code:
        line.key_card_code = payload.key_card_code

    room.occupancy_status = OccupancyStatus.OCCUPIED
    if reservation.status in EDITABLE_LINE_STATUSES:
        reservation.status = ReservationStatus.CHECKED_IN

    # Le folio est le pivot de toute la facturation (F1.4) : il nait au
    # check-in, pas a la reservation, puisque c'est l'arrivee qui engage
    # reellement le sejour. On n'en cree pas un deuxieme si l'appelant relance
    # le check-in apres une erreur reseau (index unique partiel en base, en
    # plus de ce controle).
    existing_folio = await session.scalar(
        select(Folio.id).where(Folio.reservation_room_id == line.id, Folio.deleted_at.is_(None))
    )
    if existing_folio is None:
        session.add(
            Folio(
                hotel_id=user.hotel_id,
                number=await next_number(session, user.hotel_id, Scope.FOLIO),
                type=FolioType.GUEST,
                status=FolioStatus.OPEN,
                reservation_room_id=line.id,
                guest_id=reservation.guest_id,
                opened_at=now,
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

    evenement a part (voir housekeeping), pas une consequence automatique du
    depart.
    """
    reservation = await _get_reservation(session, reservation_id, user)
    line = await session.scalar(
        select(ReservationRoom)
        .where(
            ReservationRoom.id == room_line_id,
            ReservationRoom.reservation_id == reservation.id,
            ReservationRoom.deleted_at.is_(None),
        )
        .with_for_update()
        .execution_options(populate_existing=True)
    )
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

    if all(r.status == ReservationStatus.CHECKED_OUT for r in _active_lines(reservation)):
        reservation.status = ReservationStatus.CHECKED_OUT

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
