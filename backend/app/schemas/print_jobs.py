"""Schemas Pydantic pour la file d'impression."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict

from app.models.enums import PrintJobStatus


class PrintJobOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    document_type_id: uuid.UUID
    printer_id: uuid.UUID | None
    payload: dict | None
    status: PrintJobStatus
    attempts: int
    last_error: str | None
    is_duplicate: bool
    original_job_id: uuid.UUID | None
    source_table: str | None
    source_id: uuid.UUID | None
    sent_at: dt.datetime | None
    printed_at: dt.datetime | None


class FailIn(BaseModel):
    error: str
