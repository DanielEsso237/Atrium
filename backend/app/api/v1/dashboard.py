"""Route dashboard : synthese operationnelle (cahier des charges, paragraphe 5.1)."""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.db.session import get_session
from app.models import HousekeepingTask, Reservation, ReservationRoom, User
from app.models.enums import ReservationStatus, TaskStatus
from app.schemas.dashboard import DashboardSummary, OccupancySummary, RevenueByCategory

router = APIRouter(prefix="/dashboard", tags=["dashboard"])


@router.get("/summary", response_model=DashboardSummary)
async def get_summary(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> DashboardSummary:
    """Alimente l'ecran principal (paragraphe 5.1) : occupation, arrivees/

    departs du jour, CA du jour, chambres a nettoyer -- en une seule route
    plutot que d'obliger le client a assembler six appels differents.
    Ouvert a tout utilisateur connecte : c'est l'ecran d'accueil de tout le
    monde sur tablette, pas un rapport reserve a la direction.
    """
    today = dt.date.today()

    occ_row = (
        await session.execute(
            text(
                "SELECT total_rooms, occupied_rooms, vacant_rooms, "
                "out_of_order_rooms, occupancy_rate_pct "
                "FROM v_occupancy WHERE hotel_id = :hotel_id"
            ),
            {"hotel_id": str(user.hotel_id)},
        )
    ).mappings().first()
    occupancy = (
        OccupancySummary(**occ_row)
        if occ_row
        else OccupancySummary(
            total_rooms=0,
            occupied_rooms=0,
            vacant_rooms=0,
            out_of_order_rooms=0,
            occupancy_rate_pct=None,
        )
    )

    active_reservations = (
        await session.scalar(
            select(func.count())
            .select_from(Reservation)
            .where(
                Reservation.hotel_id == user.hotel_id,
                Reservation.status.in_(
                    (
                        ReservationStatus.PENDING,
                        ReservationStatus.CONFIRMED,
                        ReservationStatus.CHECKED_IN,
                    )
                ),
            )
        )
        or 0
    )

    arrivals_today = (
        await session.scalar(
            select(func.count())
            .select_from(ReservationRoom)
            .join(Reservation, Reservation.id == ReservationRoom.reservation_id)
            .where(
                Reservation.hotel_id == user.hotel_id,
                ReservationRoom.arrival_date == today,
                ReservationRoom.status.in_(
                    (ReservationStatus.PENDING, ReservationStatus.CONFIRMED)
                ),
            )
        )
        or 0
    )

    departures_today = (
        await session.scalar(
            select(func.count())
            .select_from(ReservationRoom)
            .join(Reservation, Reservation.id == ReservationRoom.reservation_id)
            .where(
                Reservation.hotel_id == user.hotel_id,
                ReservationRoom.departure_date == today,
                ReservationRoom.status == ReservationStatus.CHECKED_IN,
            )
        )
        or 0
    )

    revenue_rows = (
        (
            await session.execute(
                text(
                    "SELECT category, amount FROM v_daily_revenue "
                    "WHERE hotel_id = :hotel_id AND business_date = :today"
                ),
                {"hotel_id": str(user.hotel_id), "today": today},
            )
        )
        .mappings()
        .all()
    )
    revenue_by_category = [RevenueByCategory(**row) for row in revenue_rows]
    revenue_total = sum(row.amount for row in revenue_by_category)

    rooms_to_clean = (
        await session.scalar(
            select(func.count())
            .select_from(HousekeepingTask)
            .where(
                HousekeepingTask.hotel_id == user.hotel_id,
                HousekeepingTask.business_date == today,
                HousekeepingTask.status.in_((TaskStatus.PENDING, TaskStatus.ASSIGNED)),
            )
        )
        or 0
    )

    return DashboardSummary(
        business_date=today,
        occupancy=occupancy,
        active_reservations=active_reservations,
        arrivals_today=arrivals_today,
        departures_today=departures_today,
        today_revenue_total=revenue_total,
        today_revenue_by_category=revenue_by_category,
        rooms_to_clean=rooms_to_clean,
    )
