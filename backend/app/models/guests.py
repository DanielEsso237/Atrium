"""Clients : particuliers, societes, pieces d'identite."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    BigInteger,
    Boolean,
    Date,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import HotelScoped, SyncBase
from app.models.enums import IdDocumentType, UploadState
from app.models.rooms import _enum


class Company(SyncBase, HotelScoped):
    """Societe, agence de voyage ou tour-operateur.

    Absente du cahier des charges, mais indissociable d'une facturation
    hoteliere reelle : le debiteur d'une facture n'est pas toujours l'occupant
    de la chambre. Sans cette table, impossible d'emettre une facture au nom
    d'une entreprise ni de gerer un encours client.
    """

    __tablename__ = "companies"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(160), index=True)
    tax_id: Mapped[str | None] = mapped_column(String(40), default=None)
    address: Mapped[str | None] = mapped_column(String(255), default=None)
    city: Mapped[str | None] = mapped_column(String(80), default=None)
    country: Mapped[str | None] = mapped_column(String(80), default=None)
    contact_name: Mapped[str | None] = mapped_column(String(120), default=None)
    phone: Mapped[str | None] = mapped_column(String(40), default=None)
    email: Mapped[str | None] = mapped_column(String(160), default=None)
    credit_limit: Mapped[int] = mapped_column(BigInteger, default=0)
    payment_terms_days: Mapped[int] = mapped_column(default=0)
    discount_rate: Mapped[int] = mapped_column(Integer, default=0)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    notes: Mapped[str | None] = mapped_column(Text, default=None)


class Guest(SyncBase, HotelScoped):
    """Fiche client (F1.6).

    C'est la seule table porteuse de donnees personnelles en clair. Ce
    cloisonnement est deliberé : il concentre sur un perimetre reduit le
    chiffrement au repos (exigence 6.2) et le droit a l'effacement (RGPD,
    paragraphe 8), au lieu de les disperser dans toute la base.
    """

    __tablename__ = "guests"
    __table_args__ = (
        UniqueConstraint("hotel_id", "code"),
        Index("ix_guests_last_name", "last_name"),
        Index("ix_guests_phone", "phone"),
        Index("ix_guests_email", "email"),
        Index("ix_guests_id_document_number", "id_document_number"),
    )

    code: Mapped[str] = mapped_column(String(32))
    title: Mapped[str | None] = mapped_column(String(16), default=None)
    first_name: Mapped[str] = mapped_column(String(80))
    last_name: Mapped[str] = mapped_column(String(80))
    birth_date: Mapped[dt.date | None] = mapped_column(Date, default=None)
    birth_place: Mapped[str | None] = mapped_column(String(120), default=None)
    nationality: Mapped[str | None] = mapped_column(String(80), default=None)
    gender: Mapped[str | None] = mapped_column(String(16), default=None)

    id_document_type: Mapped[IdDocumentType | None] = mapped_column(
        _enum(IdDocumentType, "id_document_type"), default=None
    )
    id_document_number: Mapped[str | None] = mapped_column(String(64), default=None)
    id_document_expiry: Mapped[dt.date | None] = mapped_column(Date, default=None)

    email: Mapped[str | None] = mapped_column(String(160), default=None)
    phone: Mapped[str | None] = mapped_column(String(40), default=None)
    phone_alt: Mapped[str | None] = mapped_column(String(40), default=None)
    address: Mapped[str | None] = mapped_column(String(255), default=None)
    city: Mapped[str | None] = mapped_column(String(80), default=None)
    postal_code: Mapped[str | None] = mapped_column(String(20), default=None)
    country: Mapped[str | None] = mapped_column(String(80), default=None)

    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("companies.id", ondelete="SET NULL"), default=None, index=True
    )

    # Preferences libres : etage eleve, chambre non-fumeur, oreiller ferme,
    # allergies. Champ JSON plutot qu'un schema fige, parce que chaque hotel
    # suit ses propres criteres et qu'ils changent souvent.
    preferences: Mapped[dict | None] = mapped_column(JSONB, default=None)
    notes: Mapped[str | None] = mapped_column(Text, default=None)
    is_vip: Mapped[bool] = mapped_column(Boolean, default=False)
    is_blacklisted: Mapped[bool] = mapped_column(Boolean, default=False)
    blacklist_reason: Mapped[str | None] = mapped_column(String(255), default=None)

    # RGPD : consentement explicite et horodate, separe de l'adresse courriel.
    marketing_consent: Mapped[bool] = mapped_column(Boolean, default=False)
    consent_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    anonymized_at: Mapped[dt.datetime | None] = mapped_column(default=None)

    company: Mapped[Company | None] = relationship(lazy="joined")

    @property
    def full_name(self) -> str:
        return " ".join(p for p in (self.title, self.first_name, self.last_name) if p)


class GuestDocument(SyncBase):
    """Scan ou photo d'une piece d'identite.

    Comme toutes les pieces jointes du systeme, le fichier existe d'abord
    localement sur la tablette (`file_path_local`) puis recoit une URL serveur
    apres televersement. Un binaire ne transite pas par la file d'attente JSON
    de synchronisation : c'est un worker distinct qui le remonte, et
    `upload_state` suit son avancement.
    """

    __tablename__ = "guest_documents"

    guest_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("guests.id", ondelete="CASCADE"), index=True
    )
    doc_type: Mapped[IdDocumentType] = mapped_column(_enum(IdDocumentType, "doc_type"))
    file_path_local: Mapped[str | None] = mapped_column(String(255), default=None)
    file_url: Mapped[str | None] = mapped_column(String(512), default=None)
    mime_type: Mapped[str | None] = mapped_column(String(80), default=None)
    size_bytes: Mapped[int | None] = mapped_column(default=None)
    upload_state: Mapped[UploadState] = mapped_column(
        _enum(UploadState, "upload_state"), default=UploadState.PENDING
    )
    captured_at: Mapped[dt.datetime | None] = mapped_column(default=None)
