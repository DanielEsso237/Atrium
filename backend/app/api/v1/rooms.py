"""Routes chambres (hebergement)."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import (
    Floor,
    Folio,
    FolioItem,
    Guest,
    Reservation,
    ReservationRoom,
    Room,
    RoomType,
    User,
)
from app.models.enums import OccupancyStatus, ReservationStatus
from app.schemas.rooms import (
    RoomChargeOut,
    RoomDetailOut,
    RoomFolioOut,
    RoomIn,
    RoomOut,
    RoomStayOut,
    RoomUpdate,
)

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


# Profondeur des listes de la fiche : de quoi remplir le panneau de detail
# sans transferer tout l'historique de la chambre a chaque ouverture.
STAY_HISTORY_LIMIT = 10
RECENT_CHARGES_LIMIT = 10


@router.get("/{room_id}", response_model=RoomDetailOut)
async def get_room(
    room_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("rooms.read")),
) -> RoomDetailOut:
    """Fiche complete d'une chambre (paragraphe 5.2) : type, prix, etage, les

    trois axes d'etat, le sejour en cours (client, dates), le solde de son
    folio, ses dernieres consommations et l'historique des sejours.

    Quatre requetes au plus, toutes sur index, et uniquement les colonnes
    affichees : `Reservation` et `Folio` chargent sinon toutes leurs lignes
    (relations `selectin`) pour rien.
    """
    room = await session.scalar(
        select(Room).where(
            Room.id == room_id, Room.hotel_id == user.hotel_id, Room.deleted_at.is_(None)
        )
    )
    if room is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Chambre introuvable.")

    # Sejour en cours et historique en une requete : le CHECKED_IN (s'il y en
    # a un) passe devant, puis les departs du plus recent au plus ancien.
    stays = (
        await session.execute(
            select(
                Reservation.id.label("reservation_id"),
                ReservationRoom.id.label("reservation_room_id"),
                Reservation.reference,
                Reservation.guest_id,
                func.concat_ws(" ", Guest.first_name, Guest.last_name).label("guest_name"),
                ReservationRoom.arrival_date,
                ReservationRoom.departure_date,
                ReservationRoom.status,
                ReservationRoom.checked_in_at,
                ReservationRoom.checked_out_at,
            )
            .join(Reservation, Reservation.id == ReservationRoom.reservation_id)
            .join(Guest, Guest.id == Reservation.guest_id)
            .where(
                ReservationRoom.room_id == room.id,
                ReservationRoom.deleted_at.is_(None),
                ReservationRoom.status.in_(
                    (ReservationStatus.CHECKED_IN, ReservationStatus.CHECKED_OUT)
                ),
            )
            .order_by(
                (ReservationRoom.status == ReservationStatus.CHECKED_IN).desc(),
                ReservationRoom.checked_out_at.desc().nullslast(),
            )
            .limit(STAY_HISTORY_LIMIT + 1)
        )
    ).mappings().all()

    current = None
    if stays and stays[0]["status"] == ReservationStatus.CHECKED_IN:
        current = RoomStayOut(**stays[0])
        stays = stays[1:]
    history = [RoomStayOut(**row) for row in stays[:STAY_HISTORY_LIMIT]]

    folio = None
    charges: list[RoomChargeOut] = []
    if current is not None:
        folio_row = (
            await session.execute(
                select(
                    Folio.id,
                    Folio.number,
                    Folio.charges_total,
                    Folio.payments_total,
                    Folio.balance,
                )
                .where(
                    Folio.reservation_room_id == current.reservation_room_id,
                    Folio.deleted_at.is_(None),
                )
                .order_by(Folio.opened_at.desc().nullslast())
                .limit(1)
            )
        ).mappings().first()
        if folio_row is not None:
            folio = RoomFolioOut(**folio_row)
            charges = [
                RoomChargeOut(**row)
                for row in (
                    await session.execute(
                        select(
                            FolioItem.id,
                            FolioItem.category,
                            FolioItem.label,
                            FolioItem.quantity,
                            FolioItem.amount,
                            FolioItem.business_date,
                            FolioItem.posted_at,
                        )
                        .where(
                            FolioItem.folio_id == folio.id,
                            FolioItem.is_void.is_(False),
                            FolioItem.deleted_at.is_(None),
                        )
                        .order_by(
                            FolioItem.posted_at.desc().nullslast(), FolioItem.created_at.desc()
                        )
                        .limit(RECENT_CHARGES_LIMIT)
                    )
                ).mappings()
            ]

    return RoomDetailOut(
        **RoomOut.model_validate(room).model_dump(),
        price=room.room_type.default_rate,
        floor_id=room.floor_id,
        is_active=room.is_active,
        out_of_order_reason=room.out_of_order_reason,
        out_of_order_until=room.out_of_order_until,
        notes=room.notes,
        current_stay=current,
        folio=folio,
        recent_charges=charges,
        stay_history=history,
    )


@router.patch("/{room_id}", response_model=RoomOut)
async def update_room(
    room_id: uuid.UUID,
    payload: RoomUpdate,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("rooms.write")),
) -> Room:
    """Numero, type, etage, activation. `is_out_of_order` n'est pas modifiable

    ici : il reste pilote par les tickets de maintenance bloquants.

    Une chambre occupee ne change ni de type (le sejour en cours a ete vendu
    dans sa categorie) ni d'etat actif (elle disparaitrait du plan avec un
    client dedans).
    """
    room = await session.scalar(
        select(Room)
        .where(Room.id == room_id, Room.hotel_id == user.hotel_id, Room.deleted_at.is_(None))
        .with_for_update(of=Room)
    )
    if room is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Chambre introuvable.")

    fields = payload.model_dump(exclude_unset=True)
    # `floor_id: null` retire la chambre de son etage ; ailleurs null = inchange.
    fields = {k: v for k, v in fields.items() if v is not None or k == "floor_id"}
    occupied = room.occupancy_status == OccupancyStatus.OCCUPIED

    if "room_type_id" in fields and fields["room_type_id"] != room.room_type_id:
        if occupied:
            raise HTTPException(
                status.HTTP_409_CONFLICT, "Chambre occupee : type non modifiable."
            )
        room_type = await session.get(RoomType, fields["room_type_id"])
        if room_type is None or room_type.hotel_id != user.hotel_id or room_type.deleted_at:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Type de chambre invalide.")
    if fields.get("floor_id") is not None:
        floor = await session.get(Floor, fields["floor_id"])
        if floor is None or floor.hotel_id != user.hotel_id or floor.deleted_at:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Etage invalide.")
    if fields.get("is_active") is False and occupied:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Chambre occupee : desactivation impossible."
        )

    for field, value in fields.items():
        setattr(room, field, value)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Ce numero de chambre existe deja."
        ) from exc
    await session.refresh(room, attribute_names=["room_type", "floor"])
    return room
