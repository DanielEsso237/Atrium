"""Schemas Pydantic pour le housekeeping (F2.1-F2.2)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict

from app.models.enums import HousekeepingTaskType, Priority, TaskStatus


class HousekeepingTaskIn(BaseModel):
    room_id: uuid.UUID
    type: HousekeepingTaskType
    priority: Priority = Priority.NORMAL
    business_date: dt.date
    notes: str | None = None


class HousekeepingTaskOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    room_id: uuid.UUID
    type: HousekeepingTaskType
    status: TaskStatus
    priority: Priority
    business_date: dt.date
    assigned_to: uuid.UUID | None
    assigned_at: dt.datetime | None
    started_at: dt.datetime | None
    finished_at: dt.datetime | None
    duration_minutes: int | None
    inspected_by: uuid.UUID | None
    inspected_at: dt.datetime | None
    notes: str | None


class AssignIn(BaseModel):
    user_id: uuid.UUID
