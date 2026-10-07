"""Corrections des colonnes, testees sans modifier une base de developpement."""

import datetime as dt
import uuid
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.housekeeping import revert_task
from app.api.v1.maintenance import revert_ticket
from app.models import HousekeepingTask, MaintenanceTicket, Room, User
from app.models.enums import HousekeepingStatus, TaskStatus, TicketStatus
from app.schemas.housekeeping import RevertIn as CleaningRevert
from app.schemas.maintenance import RevertIn as TicketRevert


def context():
    hotel = uuid.uuid4()
    user = User(id=uuid.uuid4(), hotel_id=hotel)
    room = Room(id=uuid.uuid4(), hotel_id=hotel, is_out_of_order=False)
    session = AsyncMock(spec=AsyncSession)
    return user, room, session


@pytest.mark.parametrize("source,target", [
    (TaskStatus.IN_PROGRESS, TaskStatus.PENDING),
    (TaskStatus.DONE, TaskStatus.IN_PROGRESS),
    (TaskStatus.INSPECTED, TaskStatus.PENDING),
])
async def test_cleaning_revert_updates_room_and_can_be_replayed(source, target):
    user, room, session = context()
    now = dt.datetime.now(dt.timezone.utc)
    task = HousekeepingTask(id=uuid.uuid4(), hotel_id=user.hotel_id, room_id=room.id,
        status=source, deleted_at=None, assigned_to=user.id, assigned_at=now,
        started_at=now, finished_at=now, duration_minutes=12,
        inspected_at=now, inspected_by=user.id)
    session.get.side_effect = [task, room]
    payload = CleaningRevert(from_status=source, status=target)
    result = await revert_task(task.id, payload, session, user)
    assert result.status == target
    assert result.finished_at is result.duration_minutes is None
    assert result.inspected_at is result.inspected_by is None
    assert room.housekeeping_status == (
        HousekeepingStatus.DIRTY if target == TaskStatus.PENDING else HousekeepingStatus.IN_PROGRESS
    )
    if target == TaskStatus.PENDING:
        assert result.started_at is result.assigned_to is None
    session.commit.assert_awaited_once()
    session.get.side_effect = None
    session.get.return_value = task
    assert await revert_task(task.id, payload, session, user) is task
    session.commit.assert_awaited_once()  # Le rejeu ne recommence pas les horodatages.


@pytest.mark.parametrize("source,target", [
    (TicketStatus.ASSIGNED, TicketStatus.OPEN),
    (TicketStatus.RESOLVED, TicketStatus.ASSIGNED),
    (TicketStatus.RESOLVED, TicketStatus.OPEN),
    (TicketStatus.CLOSED, TicketStatus.RESOLVED),
])
async def test_ticket_revert_and_reopening_a_blocking_room(source, target):
    user, room, session = context()
    now = dt.datetime.now(dt.timezone.utc)
    ticket = MaintenanceTicket(id=uuid.uuid4(), hotel_id=user.hotel_id, room_id=room.id,
        status=source, deleted_at=None, blocks_room=True, assigned_to=user.id,
        assigned_at=now, resolved_at=now, resolution="Joint change", closed_at=now)
    session.get.side_effect = [ticket, room]
    payload = TicketRevert(from_status=source, status=target)
    result = await revert_ticket(ticket.id, payload, session, user)
    assert result.status == target
    assert result.closed_at is None
    if target != TicketStatus.RESOLVED:
        assert result.resolution is result.resolved_at is None
    if target == TicketStatus.OPEN:
        assert result.assigned_to is result.assigned_at is None
    assert room.is_out_of_order is (source == TicketStatus.CLOSED)
    session.commit.assert_awaited_once()
    session.get.side_effect = None
    session.get.return_value = ticket
    assert await revert_ticket(ticket.id, payload, session, user) is ticket
    session.commit.assert_awaited_once()


@pytest.mark.parametrize("kind", ["cleaning", "maintenance"])
async def test_revert_rejects_stale_status_and_other_hotels(kind):
    user, room, session = context()
    if kind == "cleaning":
        entity = HousekeepingTask(id=uuid.uuid4(), hotel_id=user.hotel_id, room_id=room.id,
            deleted_at=None, status=TaskStatus.DONE)
        payload = CleaningRevert(from_status=TaskStatus.IN_PROGRESS, status=TaskStatus.PENDING)
        call = revert_task
    else:
        entity = MaintenanceTicket(id=uuid.uuid4(), hotel_id=user.hotel_id, room_id=room.id,
            deleted_at=None, status=TicketStatus.CLOSED)
        payload = TicketRevert(from_status=TicketStatus.RESOLVED, status=TicketStatus.OPEN)
        call = revert_ticket
    session.get.return_value = entity
    with pytest.raises(HTTPException) as error:
        await call(entity.id, payload, session, user)
    assert error.value.status_code == 409
    session.commit.assert_not_awaited()
    entity.hotel_id = uuid.uuid4()
    with pytest.raises(HTTPException) as error:
        await call(entity.id, payload, session, user)
    assert error.value.status_code == 404
    session.commit.assert_not_awaited()


@pytest.mark.parametrize("kind", ["cleaning", "maintenance"])
async def test_revert_rejects_forward_jumps(kind):
    user, room, session = context()
    if kind == "cleaning":
        entity = HousekeepingTask(id=uuid.uuid4(), hotel_id=user.hotel_id, deleted_at=None,
            status=TaskStatus.PENDING)
        payload = CleaningRevert(from_status=TaskStatus.PENDING, status=TaskStatus.DONE)
        call = revert_task
    else:
        entity = MaintenanceTicket(id=uuid.uuid4(), hotel_id=user.hotel_id, deleted_at=None,
            status=TicketStatus.OPEN)
        payload = TicketRevert(from_status=TicketStatus.OPEN, status=TicketStatus.RESOLVED)
        call = revert_ticket
    session.get.return_value = entity
    with pytest.raises(HTTPException) as error:
        await call(entity.id, payload, session, user)
    assert error.value.status_code == 409
    session.commit.assert_not_awaited()
