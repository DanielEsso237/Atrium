"""Les tablettes et leurs files bloquees (voir `models.admin.SyncBlock`)."""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class DeviceIn(BaseModel):
    """La tablette se presente. Son id est tire une fois pour toutes sur la
    tablette et ne change plus : c'est lui qui la reconnait d'un echange a
    l'autre, quel que soit l'agent connecte."""

    id: uuid.UUID
    # Ne sert qu'a la premiere presentation : un nom donne ensuite par
    # l'administrateur ne doit pas revenir au nom par defaut.
    name: str = Field(min_length=1, max_length=80)
    app_version: str | None = Field(default=None, max_length=20)
    os_version: str | None = Field(default=None, max_length=40)


class DeviceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    app_version: str | None
    os_version: str | None
    is_active: bool
    last_seen_at: dt.datetime | None
    updated_at: dt.datetime


class SyncBlockIn(BaseModel):
    """Le blocage tel que la tablette le voit. L'id vient d'elle : un renvoi
    met le rapport a jour au lieu d'en creer un second."""

    id: uuid.UUID
    device: DeviceIn
    author_id: uuid.UUID | None = None
    entity_table: str = Field(min_length=1, max_length=64)
    entity_id: uuid.UUID
    operation: str = Field(min_length=1, max_length=8)
    payload: dict[str, Any] | None = None
    http_status: int | None = None
    reason: str | None = Field(default=None, max_length=4000)
    written_at: dt.datetime | None = None
    blocked_at: dt.datetime
    pending_behind: int = Field(default=0, ge=0)
    # La tablette dit si l'ecriture peut s'abandonner sans laisser d'autre
    # saisie sans objet, et sinon pourquoi.
    abandonable: bool = False
    abandon_note: str | None = Field(default=None, max_length=500)


class SyncBlockDecideIn(BaseModel):
    """Un responsable abandonne l'ecriture refusee. Pas de « Reessayer » :
    la file renvoie deja l'ecriture a chaque echange complet."""

    decision: Literal["ABANDON"]
    reason: str = Field(min_length=3, max_length=500)


class SyncDecisionOut(BaseModel):
    """Ce que la tablette bloquee vient lire : la decision, sans le reste du
    rapport."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    decision: str
    decision_reason: str | None
    decided_by: uuid.UUID | None
    decided_at: dt.datetime | None


class SyncBlockResolveIn(BaseModel):
    # SENT : l'ecriture est passee. REMOVED : elle a quitte la file sans
    # passer (abandonnee, ou la base locale remise a zero).
    resolution: Literal["SENT", "REMOVED"]
    resolved_at: dt.datetime


class SyncBlockOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    device_id: uuid.UUID
    author_id: uuid.UUID | None
    reported_by: uuid.UUID | None
    entity_table: str
    entity_id: uuid.UUID
    operation: str
    payload: dict[str, Any] | None
    http_status: int | None
    reason: str | None
    written_at: dt.datetime | None
    blocked_at: dt.datetime
    reported_at: dt.datetime
    pending_behind: int
    status: str
    resolved_at: dt.datetime | None
    resolution: str | None
    abandonable: bool
    abandon_note: str | None
    decision: str | None
    decision_reason: str | None
    decided_by: uuid.UUID | None
    decided_at: dt.datetime | None
    updated_at: dt.datetime
