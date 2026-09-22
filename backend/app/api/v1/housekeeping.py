"""Routes housekeeping : taches de nettoyage (F2.1-F2.2)."""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import HousekeepingTask, Room, User
from app.models.enums import HousekeepingStatus, TaskStatus
from app.schemas.housekeeping import AssignIn, HousekeepingTaskIn, HousekeepingTaskOut

router = APIRouter(prefix="/housekeeping-tasks", tags=["housekeeping"])


async def _get_task(session: AsyncSession, task_id: uuid.UUID, user: User) -> HousekeepingTask:
    task = await session.get(HousekeepingTask, task_id)
    if task is None or task.hotel_id != user.hotel_id or task.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Tache introuvable.")
    return task


@router.get("", response_model=list[HousekeepingTaskOut])
async def list_tasks(
    business_date: dt.date | None = None,
    status_filter: TaskStatus | None = Query(None, alias="status"),
    assigned_to: uuid.UUID | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("housekeeping.read")),
) -> list[HousekeepingTask]:
    stmt = select(HousekeepingTask).where(
        HousekeepingTask.hotel_id == user.hotel_id, HousekeepingTask.deleted_at.is_(None)
    )
    if business_date:
        stmt = stmt.where(HousekeepingTask.business_date == business_date)
    if status_filter:
        stmt = stmt.where(HousekeepingTask.status == status_filter)
    if assigned_to:
        stmt = stmt.where(HousekeepingTask.assigned_to == assigned_to)
    stmt = stmt.order_by(HousekeepingTask.priority.desc(), HousekeepingTask.business_date)
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.post("", response_model=HousekeepingTaskOut, status_code=status.HTTP_201_CREATED)
async def create_task(
    payload: HousekeepingTaskIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("housekeeping.manage")),
) -> HousekeepingTask:
    task = HousekeepingTask(
        hotel_id=user.hotel_id, status=TaskStatus.PENDING, **payload.model_dump()
    )
    session.add(task)
    await session.commit()
    await session.refresh(task)
    return task


@router.post("/{task_id}/assign", response_model=HousekeepingTaskOut)
async def assign_task(
    task_id: uuid.UUID,
    payload: AssignIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("housekeeping.manage")),
) -> HousekeepingTask:
    task = await _get_task(session, task_id, user)
    if task.status not in (TaskStatus.PENDING, TaskStatus.ASSIGNED):
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible d'assigner (statut actuel : {task.status})."
        )
    task.assigned_to = payload.user_id
    task.assigned_at = dt.datetime.now(dt.timezone.utc)
    task.status = TaskStatus.ASSIGNED
    await session.commit()
    await session.refresh(task)
    return task


@router.post("/{task_id}/start", response_model=HousekeepingTaskOut)
async def start_task(
    task_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("housekeeping.manage")),
) -> HousekeepingTask:
    task = await _get_task(session, task_id, user)
    if task.status not in (TaskStatus.PENDING, TaskStatus.ASSIGNED):
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible de demarrer (statut actuel : {task.status})."
        )
    task.status = TaskStatus.IN_PROGRESS
    task.started_at = dt.datetime.now(dt.timezone.utc)
    room = await session.get(Room, task.room_id)
    if room is not None:
        room.housekeeping_status = HousekeepingStatus.IN_PROGRESS
    await session.commit()
    await session.refresh(task)
    return task


@router.post("/{task_id}/finish", response_model=HousekeepingTaskOut)
async def finish_task(
    task_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("housekeeping.manage")),
) -> HousekeepingTask:
    """F2.1/F2.2 -- termine la tache et remet la chambre propre.

    `duration_minutes` calcule ici alimente plus tard le dimensionnement des
    equipes (voir le commentaire du modele `HousekeepingTask`).
    """
    task = await _get_task(session, task_id, user)
    if task.status != TaskStatus.IN_PROGRESS:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible de terminer (statut actuel : {task.status})."
        )
    now = dt.datetime.now(dt.timezone.utc)
    task.status = TaskStatus.DONE
    task.finished_at = now
    if task.started_at is not None:
        task.duration_minutes = int((now - task.started_at).total_seconds() // 60)
    room = await session.get(Room, task.room_id)
    if room is not None:
        room.housekeeping_status = HousekeepingStatus.CLEAN
    await session.commit()
    await session.refresh(task)
    return task


@router.post("/{task_id}/inspect", response_model=HousekeepingTaskOut)
async def inspect_task(
    task_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("housekeeping.manage")),
) -> HousekeepingTask:
    task = await _get_task(session, task_id, user)
    if task.status != TaskStatus.DONE:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible d'inspecter (statut actuel : {task.status})."
        )
    task.status = TaskStatus.INSPECTED
    task.inspected_by = user.id
    task.inspected_at = dt.datetime.now(dt.timezone.utc)
    room = await session.get(Room, task.room_id)
    if room is not None:
        room.housekeeping_status = HousekeepingStatus.INSPECTED
    await session.commit()
    await session.refresh(task)
    return task
