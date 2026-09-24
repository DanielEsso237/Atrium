"""Routes maintenance : tickets et interventions (F2.3, F4.1-F4.4)."""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import MaintenanceIntervention, MaintenanceTicket, Room, User
from app.models.enums import TicketStatus
from app.schemas.maintenance import (
    AssignIn,
    InterventionIn,
    InterventionOut,
    MaintenanceTicketIn,
    MaintenanceTicketOut,
    ResolveIn,
)
from app.services.numbering import Scope, next_number
from app.services.printing import enqueue_print_job

router = APIRouter(prefix="/maintenance-tickets", tags=["maintenance"])


async def _get_ticket(session: AsyncSession, ticket_id: uuid.UUID, user: User) -> MaintenanceTicket:
    ticket = await session.get(MaintenanceTicket, ticket_id)
    if ticket is None or ticket.hotel_id != user.hotel_id or ticket.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ticket introuvable.")
    return ticket


@router.get("", response_model=list[MaintenanceTicketOut])
async def list_tickets(
    status_filter: TicketStatus | None = Query(None, alias="status"),
    room_id: uuid.UUID | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("maintenance.read")),
) -> list[MaintenanceTicket]:
    stmt = select(MaintenanceTicket).where(
        MaintenanceTicket.hotel_id == user.hotel_id, MaintenanceTicket.deleted_at.is_(None)
    )
    if status_filter:
        stmt = stmt.where(MaintenanceTicket.status == status_filter)
    if room_id:
        stmt = stmt.where(MaintenanceTicket.room_id == room_id)
    stmt = stmt.order_by(MaintenanceTicket.priority.desc(), MaintenanceTicket.reported_at.desc())
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.post("", response_model=MaintenanceTicketOut, status_code=status.HTTP_201_CREATED)
async def create_ticket(
    payload: MaintenanceTicketIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("maintenance.manage")),
) -> MaintenanceTicket:
    """F2.3/F4.1 -- ouvrir un ticket bloquant sort la chambre de la vente

    immediatement (`blocks_room` -> `rooms.is_out_of_order`), pas seulement
    au moment ou un technicien s'en occupe.
    """
    ticket = MaintenanceTicket(
        hotel_id=user.hotel_id,
        number=await next_number(session, user.hotel_id, Scope.MAINTENANCE_TICKET),
        status=TicketStatus.OPEN,
        reported_by=user.id,
        reported_at=dt.datetime.now(dt.timezone.utc),
        **payload.model_dump(),
    )
    session.add(ticket)

    if payload.blocks_room and payload.room_id is not None:
        room = await session.get(Room, payload.room_id)
        if room is not None and room.hotel_id == user.hotel_id:
            room.is_out_of_order = True

    await session.flush()  # pour avoir ticket.number avant le payload
    await enqueue_print_job(
        session,
        user.hotel_id,
        "MAINTENANCE_ORDER",
        payload={
            "ticket_number": ticket.number,
            "title": ticket.title,
            "priority": ticket.priority.value,
            "location": ticket.location,
        },
        source_table="maintenance_tickets",
        source_id=ticket.id,
        requested_by=user.id,
    )

    await session.commit()
    await session.refresh(ticket)
    return ticket


@router.get("/{ticket_id}", response_model=MaintenanceTicketOut)
async def get_ticket(
    ticket_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("maintenance.read")),
) -> MaintenanceTicket:
    return await _get_ticket(session, ticket_id, user)


@router.post("/{ticket_id}/assign", response_model=MaintenanceTicketOut)
async def assign_ticket(
    ticket_id: uuid.UUID,
    payload: AssignIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("maintenance.manage")),
) -> MaintenanceTicket:
    ticket = await _get_ticket(session, ticket_id, user)
    if ticket.status not in (TicketStatus.OPEN, TicketStatus.ASSIGNED):
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible d'assigner (statut actuel : {ticket.status})."
        )
    ticket.assigned_to = payload.user_id
    ticket.assigned_at = dt.datetime.now(dt.timezone.utc)
    ticket.status = TicketStatus.ASSIGNED
    await session.commit()
    await session.refresh(ticket)
    return ticket


@router.post(
    "/{ticket_id}/interventions",
    response_model=InterventionOut,
    status_code=status.HTTP_201_CREATED,
)
async def add_intervention(
    ticket_id: uuid.UUID,
    payload: InterventionIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("maintenance.manage")),
) -> MaintenanceIntervention:
    """Un passage de technicien. Peut y en avoir plusieurs sur le meme

    ticket (diagnostic, commande de piece, reparation) -- voir le commentaire
    du modele `MaintenanceIntervention`.
    """
    ticket = await _get_ticket(session, ticket_id, user)
    if ticket.status in (TicketStatus.CLOSED, TicketStatus.CANCELLED):
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce ticket est deja ferme.")

    intervention = MaintenanceIntervention(
        ticket_id=ticket.id,
        technician_id=user.id,
        started_at=dt.datetime.now(dt.timezone.utc),
        description=payload.description,
        cost=payload.cost,
    )
    session.add(intervention)
    ticket.cost += payload.cost
    if ticket.status == TicketStatus.ASSIGNED:
        ticket.status = TicketStatus.IN_PROGRESS

    await session.commit()
    await session.refresh(intervention)
    return intervention


@router.post("/{ticket_id}/resolve", response_model=MaintenanceTicketOut)
async def resolve_ticket(
    ticket_id: uuid.UUID,
    payload: ResolveIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("maintenance.manage")),
) -> MaintenanceTicket:
    ticket = await _get_ticket(session, ticket_id, user)
    if ticket.status not in (TicketStatus.ASSIGNED, TicketStatus.IN_PROGRESS):
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible de resoudre (statut actuel : {ticket.status})."
        )
    ticket.status = TicketStatus.RESOLVED
    ticket.resolved_at = dt.datetime.now(dt.timezone.utc)
    ticket.resolution = payload.resolution
    await session.commit()
    await session.refresh(ticket)
    return ticket


@router.post("/{ticket_id}/close", response_model=MaintenanceTicketOut)
async def close_ticket(
    ticket_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("maintenance.manage")),
) -> MaintenanceTicket:
    """Referme la chambre bloquee si c'est elle qui l'avait ouverte (voir

    `blocks_room` a la creation) -- sans ce lien explicite, une chambre reste
    hors service parce que personne ne pense a lever le drapeau a la main.
    """
    ticket = await _get_ticket(session, ticket_id, user)
    if ticket.status != TicketStatus.RESOLVED:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible de cloturer (statut actuel : {ticket.status})."
        )
    ticket.status = TicketStatus.CLOSED
    ticket.closed_at = dt.datetime.now(dt.timezone.utc)

    if ticket.blocks_room and ticket.room_id is not None:
        room = await session.get(Room, ticket.room_id)
        if room is not None:
            room.is_out_of_order = False

    await session.commit()
    await session.refresh(ticket)
    return ticket
