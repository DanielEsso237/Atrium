"""Schemas Pydantic pour la facturation (F1.4-F1.5 du cahier des charges)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import ChargeCategory, FolioStatus, FolioType, InvoiceStatus, PaymentMethod


class FolioItemIn(BaseModel):
    id: uuid.UUID | None = Field(default=None, description="UUID v7 genere par la tablette ; absent = genere par le serveur")
    category: ChargeCategory
    label: str = Field(min_length=1, max_length=160)
    quantity: int = Field(default=1, ge=1)
    unit_price: int = Field(ge=0, description="FCFA, TTC")
    tax_rate: int = Field(default=0, ge=0, le=100)


class FolioItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    category: ChargeCategory
    label: str
    quantity: int
    unit_price: int
    amount: int
    tax_amount: int
    tax_rate: int
    business_date: dt.date
    is_void: bool
    void_reason: str | None


class FolioOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    number: str
    type: FolioType
    status: FolioStatus
    guest_id: uuid.UUID | None
    reservation_room_id: uuid.UUID | None
    charges_total: int
    payments_total: int
    balance: int
    opened_at: dt.datetime | None
    closed_at: dt.datetime | None
    items: list[FolioItemOut]


class PaymentIn(BaseModel):
    id: uuid.UUID | None = Field(default=None, description="UUID v7 genere par la tablette ; absent = genere par le serveur")
    method: PaymentMethod
    amount: int = Field(gt=0, description="FCFA")
    reference: str | None = None
    notes: str | None = None


class PaymentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    method: PaymentMethod
    amount: int
    reference: str | None
    received_at: dt.datetime | None
    is_refund: bool


class InvoiceLineOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    label: str
    quantity: int
    unit_price: int
    tax_rate: int
    tax_amount: int
    amount: int


class InvoiceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    number: str | None
    is_provisional: bool
    folio_id: uuid.UUID
    status: InvoiceStatus
    issued_at: dt.datetime | None
    subtotal: int
    tax_total: int
    total: int
    currency: str
    lines: list[InvoiceLineOut]
