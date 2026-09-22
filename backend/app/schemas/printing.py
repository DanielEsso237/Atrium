"""Schemas Pydantic pour le referentiel impression (paragraphe 4.2, regles R1-R5)."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import PrinterKind, PrinterProtocol, TemplateFormat


class PrinterIn(BaseModel):
    """`logical_name` porte la regle R4 : l'application ne connait jamais

    une adresse IP, seulement un nom (`IMP_CUISINE_01`). Remplacer une
    imprimante en panne revient a rebrancher ce nom sur une autre machine.
    """

    logical_name: str = Field(min_length=1, max_length=64)
    label: str = Field(min_length=1, max_length=120)
    kind: PrinterKind
    protocol: PrinterProtocol
    host: str | None = None
    port: int | None = None
    device_path: str | None = None
    paper_width_mm: int | None = None
    location: str | None = None
    prep_station_id: uuid.UUID | None = None
    fallback_printer_id: uuid.UUID | None = None


class PrinterOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    logical_name: str
    label: str
    kind: PrinterKind
    protocol: PrinterProtocol
    host: str | None
    port: int | None
    paper_width_mm: int | None
    location: str | None
    prep_station_id: uuid.UUID | None
    fallback_printer_id: uuid.UUID | None
    is_online: bool
    last_error: str | None


class DocumentTypeIn(BaseModel):
    """Les 7 codes de la matrice du paragraphe 4.2 (KITCHEN_TICKET,

    BAR_TICKET, GUEST_INVOICE, HK_TASK_SHEET, SHIFT_REPORT,
    MAINTENANCE_ORDER, ROOM_SERVICE_TICKET) sont les valeurs attendues pour
    `code`, mais rien ne l'impose au niveau du schema -- la liste vit dans le
    cahier des charges, pas dans une contrainte de base de code en dur.
    """

    code: str = Field(min_length=1, max_length=48)
    label: str = Field(min_length=1, max_length=120)
    default_kind: PrinterKind = PrinterKind.LASER
    copies: int = Field(default=1, ge=1)
    allow_reprint: bool = True


class DocumentTypeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    label: str
    default_kind: PrinterKind
    copies: int
    allow_reprint: bool


class PrintRouteIn(BaseModel):
    """Un critere `match_*` laisse a None est un joker (voir le modele

    `PrintRoute`). `priority` plus haut gagne quand plusieurs regles
    correspondent au meme contexte.
    """

    document_type_id: uuid.UUID
    printer_id: uuid.UUID
    match_outlet_id: uuid.UUID | None = None
    match_prep_station_id: uuid.UUID | None = None
    match_device_id: uuid.UUID | None = None
    match_role_id: uuid.UUID | None = None
    priority: int = 0
    label: str | None = None


class PrintRouteOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    document_type_id: uuid.UUID
    printer_id: uuid.UUID
    match_outlet_id: uuid.UUID | None
    match_prep_station_id: uuid.UUID | None
    match_device_id: uuid.UUID | None
    match_role_id: uuid.UUID | None
    priority: int
    label: str | None


class DocumentTemplateIn(BaseModel):
    document_type_id: uuid.UUID
    format: TemplateFormat
    content: str = Field(min_length=1)
    label: str | None = None


class DocumentTemplateOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    document_type_id: uuid.UUID
    version: int
    format: TemplateFormat
    content: str
    label: str | None
