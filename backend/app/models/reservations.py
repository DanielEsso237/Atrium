"""Reservations, sejours, nuitees, signatures."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import HotelScoped, SyncBase
from app.models.enums import (
    ReservationSource,
    ReservationStatus,
    SignatureKind,
    UploadState,
)
from app.models.rooms import _enum


class Reservation(SyncBase, HotelScoped):
    """Dossier de reservation (F1.1).

    Le dossier est le contenant commercial : un titulaire, une source, un
    statut global. Le detail operationnel vit dans `reservation_rooms`, parce
    qu'un dossier peut couvrir plusieurs chambres avec des dates et des tarifs
    differents (famille, groupe, seminaire).
    """

    __tablename__ = "reservations"
    __table_args__ = (
        UniqueConstraint("hotel_id", "reference"),
        Index("ix_reservations_dates", "arrival_date", "departure_date"),
        Index("ix_reservations_status", "status"),
        CheckConstraint("departure_date > arrival_date", name="stay_range"),
    )

    reference: Mapped[str] = mapped_column(String(32))
    guest_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("guests.id", ondelete="RESTRICT"), index=True
    )
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("companies.id", ondelete="SET NULL"), default=None, index=True
    )

    source: Mapped[ReservationSource] = mapped_column(
        _enum(ReservationSource, "reservation_source"), default=ReservationSource.DIRECT
    )
    status: Mapped[ReservationStatus] = mapped_column(
        _enum(ReservationStatus, "reservation_status"),
        default=ReservationStatus.PENDING,
    )

    arrival_date: Mapped[dt.date] = mapped_column(Date)
    departure_date: Mapped[dt.date] = mapped_column(Date)
    adults: Mapped[int] = mapped_column(default=1)
    children: Mapped[int] = mapped_column(default=0)

    estimated_total: Mapped[int] = mapped_column(BigInteger, default=0)
    deposit_amount: Mapped[int] = mapped_column(BigInteger, default=0)
    deposit_paid_at: Mapped[dt.datetime | None] = mapped_column(default=None)

    special_requests: Mapped[str | None] = mapped_column(Text, default=None)
    internal_notes: Mapped[str | None] = mapped_column(Text, default=None)
    cancelled_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    cancel_reason: Mapped[str | None] = mapped_column(String(255), default=None)

    rooms: Mapped[list[ReservationRoom]] = relationship(
        back_populates="reservation", lazy="selectin"
    )
    guest: Mapped["Guest"] = relationship(lazy="joined")  # noqa: F821

    @property
    def nights(self) -> int:
        return (self.departure_date - self.arrival_date).days


class ReservationRoom(SyncBase):
    """Une chambre reservee : c'est ici que vit le sejour.

    Toute la logique operationnelle s'accroche a cette ligne et non au dossier :
    c'est elle qu'on attribue a une chambre physique, elle qui est prise en
    charge au check-in, elle qui porte un folio. Dans un dossier de groupe,
    chaque chambre arrive et repart independamment.

    `room_id` est nullable a dessein : on reserve d'abord un *type* de chambre,
    l'attribution du numero physique arrive plus tard (souvent le jour meme).
    """

    __tablename__ = "reservation_rooms"
    __table_args__ = (
        Index(
            "ix_reservation_rooms_room_dates",
            "room_id",
            "arrival_date",
            "departure_date",
        ),
        Index("ix_reservation_rooms_status", "status"),
        CheckConstraint("departure_date > arrival_date", name="stay_range"),
    )

    reservation_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("reservations.id", ondelete="CASCADE"), index=True
    )
    room_type_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("room_types.id", ondelete="RESTRICT")
    )
    room_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rooms.id", ondelete="SET NULL"), default=None
    )
    rate_plan_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rate_plans.id", ondelete="SET NULL"), default=None
    )

    arrival_date: Mapped[dt.date] = mapped_column(Date)
    departure_date: Mapped[dt.date] = mapped_column(Date)
    adults: Mapped[int] = mapped_column(default=1)
    children: Mapped[int] = mapped_column(default=0)
    nightly_rate: Mapped[int] = mapped_column(BigInteger, default=0)

    status: Mapped[ReservationStatus] = mapped_column(
        _enum(ReservationStatus, "reservation_status"),
        default=ReservationStatus.PENDING,
    )
    checked_in_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    checked_in_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    checked_out_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    checked_out_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    key_card_code: Mapped[str | None] = mapped_column(String(64), default=None)
    notes: Mapped[str | None] = mapped_column(Text, default=None)

    # Trace de l'arbitrage serveur quand deux tablettes hors ligne ont attribue
    # la meme chambre : voir docs/01-modele-de-donnees.md, paragraphe 10.
    assignment_rejected_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    assignment_reject_reason: Mapped[str | None] = mapped_column(
        String(255), default=None
    )

    reservation: Mapped[Reservation] = relationship(back_populates="rooms")
    nights_detail: Mapped[list[StayNight]] = relationship(
        back_populates="reservation_room", lazy="selectin"
    )


class StayNight(SyncBase):
    """Une nuit facturable d'un sejour.

    Materialiser chaque nuit sert trois choses d'un coup : la facture
    detaillee ligne a ligne, le chiffre d'affaires du jour affiche au tableau
    de bord (paragraphe 5.1) sans recalculer des prorata, et la cloture
    journaliere qui poste automatiquement la charge de la nuit sur le folio.

    Le prix n'est pas constant sur un sejour -- saison, surclassement, remise
    negociee en cours de route -- donc on ne peut pas se contenter de
    multiplier un tarif unique par un nombre de nuits.
    """

    __tablename__ = "stay_nights"
    __table_args__ = (
        UniqueConstraint("reservation_room_id", "business_date"),
        Index("ix_stay_nights_business_date", "business_date"),
    )

    reservation_room_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("reservation_rooms.id", ondelete="CASCADE"), index=True
    )
    business_date: Mapped[dt.date] = mapped_column(Date)
    room_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rooms.id", ondelete="SET NULL"), default=None
    )
    rate: Mapped[int] = mapped_column(BigInteger, default=0)
    # Passe a vrai quand la charge a ete portee au folio, pour que la cloture
    # journaliere soit rejouable sans facturer deux fois la meme nuit.
    is_posted: Mapped[bool] = mapped_column(Boolean, default=False)
    posted_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    remark: Mapped[str | None] = mapped_column(String(255), default=None)

    reservation_room: Mapped[ReservationRoom] = relationship(
        back_populates="nights_detail"
    )


class ReservationGuest(SyncBase):
    """Occupants d'une chambre, au-dela du titulaire du dossier."""

    __tablename__ = "reservation_guests"
    __table_args__ = (UniqueConstraint("reservation_room_id", "guest_id"),)

    reservation_room_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("reservation_rooms.id", ondelete="CASCADE"), index=True
    )
    guest_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("guests.id", ondelete="CASCADE"), index=True
    )
    is_primary: Mapped[bool] = mapped_column(Boolean, default=False)


class Signature(SyncBase):
    """Signature electronique de check-in, de check-out ou de facture (F1.2).

    Table polymorphe (`entity_table` + `entity_id`) plutot qu'une colonne par
    usage : les signatures se ressemblent toutes et leur cycle de televersement
    est identique, alors que les entites signees se multiplieront.

    Le trace est capture hors ligne et stocke en fichier local ; l'envoi au
    serveur est une operation de synchronisation distincte de celle de la ligne
    metier, parce qu'un binaire ne passe pas par la file d'attente JSON.
    """

    __tablename__ = "signatures"
    __table_args__ = (Index("ix_signatures_entity", "entity_table", "entity_id"),)

    entity_table: Mapped[str] = mapped_column(String(64))
    entity_id: Mapped[uuid.UUID] = mapped_column()
    kind: Mapped[SignatureKind] = mapped_column(_enum(SignatureKind, "signature_kind"))
    image_path_local: Mapped[str | None] = mapped_column(String(255), default=None)
    image_url: Mapped[str | None] = mapped_column(String(512), default=None)
    upload_state: Mapped[UploadState] = mapped_column(
        _enum(UploadState, "upload_state"), default=UploadState.PENDING
    )
    signed_by_name: Mapped[str | None] = mapped_column(String(160), default=None)
    signed_at: Mapped[dt.datetime | None] = mapped_column(default=None)
