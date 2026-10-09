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
    menu_item_id: uuid.UUID | None = Field(
        default=None, description="Article de la carte vendu : fait sortir son produit du stock"
    )
    outlet_id: uuid.UUID | None = Field(
        default=None, description="Point de vente qui a servi : c'est son stock qui baisse"
    )
    unit_price: int = Field(ge=0, description="FCFA, TTC")
    tax_rate: int = Field(default=0, ge=0, le=100)
    override_by: uuid.UUID | None = Field(
        default=None,
        description="Responsable (folio.override_limit) qui autorise le depassement du seuil",
    )
    night_date: dt.date | None = Field(
        default=None,
        description=(
            "Nuitee : la nuit facturee. Une nuit deja portee au sejour n'est pas "
            "portee deux fois -- la reponse (200) designe la charge existante."
        ),
    )


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
    override_by: uuid.UUID | None = None
    # L'origine de la ligne et son auteur : sans eux, une autre tablette ne
    # sait pas a quel point de vente rattacher la vente ni quel agent l'a
    # saisie, et ses rapports filtres sont faux.
    source_table: str | None = None
    source_id: uuid.UUID | None = None
    posted_by: uuid.UUID | None = None


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


class WalkInItemIn(BaseModel):
    id: uuid.UUID | None = Field(default=None, description="UUID v7 genere par la tablette")
    category: ChargeCategory
    label: str = Field(min_length=1, max_length=160)
    quantity: int = Field(default=1, ge=1)
    menu_item_id: uuid.UUID | None = Field(
        default=None, description="Article de la carte vendu : fait sortir son produit du stock"
    )
    unit_price: int = Field(gt=0, description="FCFA, TTC")


class WalkInSaleIn(BaseModel):
    """Vente au comptoir a un client sans chambre : tout en une requete.

    Ardoise, consommations, encaissement et cloture arrivent ensemble. Une
    requete par geste aurait laisse, au premier refus, une ardoise ouverte et
    a moitie payee -- et une file d'envoi bloquee derriere.
    """

    id: uuid.UUID = Field(description="Id de l'ardoise, genere par la tablette (rejeu)")
    outlet_id: uuid.UUID
    items: list[WalkInItemIn] = Field(min_length=1)
    payment: PaymentIn
    notes: str | None = Field(default=None, max_length=255)


class PaymentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    method: PaymentMethod
    amount: int
    reference: str | None
    received_at: dt.datetime | None
    is_refund: bool
    folio_id: uuid.UUID | None
    reservation_id: uuid.UUID | None
    # Qui a encaisse, sur quelle journee et dans quelle caisse : ce que les
    # rapports filtrent (agent, moyen de paiement, periode).
    received_by: uuid.UUID | None = None
    business_date: dt.date | None = None
    cash_session_id: uuid.UUID | None = None


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
