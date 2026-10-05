"""Schemas Pydantic des pieces jointes."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict

from app.models.enums import UploadState


class AttachmentOut(BaseModel):
    """Une piece jointe telle que le serveur la tient.

    Le fichier lui-meme n'y est pas : `file_url` dit ou le lire.
    """

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    entity_table: str
    entity_id: uuid.UUID
    kind: str
    file_url: str | None
    mime_type: str | None
    size_bytes: int | None
    upload_state: UploadState
    captured_at: dt.datetime | None
    captured_by: uuid.UUID | None
    updated_at: dt.datetime
