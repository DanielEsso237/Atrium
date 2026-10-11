"""Les chambres a qui un comptoir peut porter une consommation.

L'agent d'un point de vente porte sur la chambre (`folio.charge`) sans lire
les reservations ni les ardoises de l'hotel. Sur une tablette qui ne sert
qu'au bar, « Porter a la chambre » ne proposait donc aucune chambre : elles
n'y arrivaient que si la reception s'y etait connectee avant.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import Folio, Guest, Reservation, ReservationRoom, Room, RoomType, User
from app.models.enums import FolioStatus, ReservationStatus
from app.schemas.billing import FolioOut
from app.schemas.chargeable_stays import ChargeableStayOut

router = APIRouter(prefix="/chargeable-stays", tags=["points de vente"])


@router.get("", response_model=list[ChargeableStayOut])
async def chargeable_stays(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.charge")),
) -> list[ChargeableStayOut]:
    """Les sejours en cours dont l'ardoise est ouverte, par numero de chambre."""
    lignes = await session.execute(
        select(ReservationRoom, Reservation, Guest, Room, RoomType, Folio)
        .join(Reservation, Reservation.id == ReservationRoom.reservation_id)
        .join(Guest, Guest.id == Reservation.guest_id)
        .join(Room, Room.id == ReservationRoom.room_id)
        .join(RoomType, RoomType.id == Room.room_type_id)
        .join(Folio, Folio.reservation_room_id == ReservationRoom.id)
        .where(
            Reservation.hotel_id == user.hotel_id,
            ReservationRoom.status == ReservationStatus.CHECKED_IN,
            ReservationRoom.deleted_at.is_(None),
            Reservation.deleted_at.is_(None),
            Folio.status == FolioStatus.OPEN,
            Folio.deleted_at.is_(None),
        )
        .order_by(Room.number)
    )
    return [
        ChargeableStayOut(
            stay_id=sejour.id,
            reservation_id=dossier.id,
            reservation_reference=dossier.reference,
            stay_status=sejour.status,
            arrival_date=sejour.arrival_date,
            departure_date=sejour.departure_date,
            checked_in_at=sejour.checked_in_at,
            room_id=chambre.id,
            room_number=chambre.number,
            room_type_id=categorie.id,
            room_type_code=categorie.code,
            room_type_label=categorie.label,
            guest_id=client.id,
            guest_code=client.code,
            guest_first_name=client.first_name,
            guest_last_name=client.last_name,
            guest_credit_limit=client.credit_limit,
            folio=FolioOut.model_validate(ardoise),
        )
        for sejour, dossier, client, chambre, categorie, ardoise in lignes.all()
    ]
