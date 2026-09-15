"""Hebergement : etages, types de chambres, chambres, tarifs, taxes."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import HotelScoped, RefBase, SyncBase
from app.models.enums import HousekeepingStatus, OccupancyStatus, TaxMode


def _enum(e, name: str):
    """VARCHAR + CHECK plutot qu'un ENUM natif (voir app/models/enums.py)."""
    return Enum(e, name=name, native_enum=False, length=32, validate_strings=True)


class Floor(RefBase, HotelScoped):
    __tablename__ = "floors"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(16))
    label: Mapped[str] = mapped_column(String(80))
    sort_order: Mapped[int] = mapped_column(default=0)
    # Fond de plan de l'etage pour l'ecran graphique du paragraphe 5.2.
    map_image_path: Mapped[str | None] = mapped_column(String(255), default=None)


class RoomType(RefBase, HotelScoped):
    __tablename__ = "room_types"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(16))
    label: Mapped[str] = mapped_column(String(80))
    description: Mapped[str | None] = mapped_column(Text, default=None)
    base_capacity: Mapped[int] = mapped_column(default=2)
    max_capacity: Mapped[int] = mapped_column(default=2)
    default_rate: Mapped[int] = mapped_column(BigInteger, default=0)
    amenities: Mapped[dict | None] = mapped_column(JSONB, default=None)
    photo_path: Mapped[str | None] = mapped_column(String(255), default=None)
    sort_order: Mapped[int] = mapped_column(default=0)


class Room(SyncBase, HotelScoped):
    """Chambre physique.

    Point de modelisation important : le cahier des charges (paragraphe 5.2)
    affiche un etat unique par pastille de couleur -- disponible, occupee,
    reservee, nettoyage, maintenance. C'est le bon affichage mais un mauvais
    stockage, car ces valeurs ne sont pas exclusives : une chambre peut etre
    occupee *et* en cours de nettoyage, ou en maintenance *et* sale.

    On conserve donc trois axes independants, et la pastille est calculee par
    `display_status`. Sans cela, la reception et le housekeeping s'ecrasent
    mutuellement a chaque synchronisation, puisqu'ils ecrivent le meme champ
    pour deux raisons differentes.

    Ces colonnes sont materialisees et non derivees des reservations : la
    tablette doit pouvoir peindre le plan de l'hotel instantanement et hors
    ligne, sans recalculer des intersections de dates sur toute la table.
    """

    __tablename__ = "rooms"
    __table_args__ = (
        UniqueConstraint("hotel_id", "number"),
        Index("ix_rooms_occupancy_status", "occupancy_status"),
        Index("ix_rooms_housekeeping_status", "housekeeping_status"),
    )

    number: Mapped[str] = mapped_column(String(16))
    room_type_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("room_types.id", ondelete="RESTRICT"), index=True
    )
    floor_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("floors.id", ondelete="SET NULL"), default=None, index=True
    )

    occupancy_status: Mapped[OccupancyStatus] = mapped_column(
        _enum(OccupancyStatus, "occupancy_status"), default=OccupancyStatus.VACANT
    )
    housekeeping_status: Mapped[HousekeepingStatus] = mapped_column(
        _enum(HousekeepingStatus, "housekeeping_status"),
        default=HousekeepingStatus.CLEAN,
    )
    is_out_of_order: Mapped[bool] = mapped_column(Boolean, default=False)
    out_of_order_reason: Mapped[str | None] = mapped_column(String(255), default=None)
    out_of_order_until: Mapped[dt.date | None] = mapped_column(Date, default=None)

    # Coordonnees sur le plan interactif (F1.7).
    map_x: Mapped[int | None] = mapped_column(default=None)
    map_y: Mapped[int | None] = mapped_column(default=None)

    phone_ext: Mapped[str | None] = mapped_column(String(16), default=None)
    notes: Mapped[str | None] = mapped_column(Text, default=None)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)

    room_type: Mapped[RoomType] = relationship(lazy="joined")
    floor: Mapped[Floor | None] = relationship(lazy="joined")

    @property
    def display_status(self) -> str:
        """Pastille de l'ecran 5.2, par ordre de priorite decroissante."""
        if self.is_out_of_order:
            return "MAINTENANCE"
        if (
            self.housekeeping_status
            in (
                HousekeepingStatus.IN_PROGRESS,
                HousekeepingStatus.DIRTY,
            )
            and self.occupancy_status is OccupancyStatus.VACANT
        ):
            return "CLEANING"
        if self.occupancy_status is OccupancyStatus.OCCUPIED:
            return "OCCUPIED"
        if self.occupancy_status is OccupancyStatus.RESERVED:
            return "RESERVED"
        return "AVAILABLE"


class RatePlan(RefBase, HotelScoped):
    __tablename__ = "rate_plans"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(120))
    room_type_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("room_types.id", ondelete="CASCADE"), default=None, index=True
    )
    is_default: Mapped[bool] = mapped_column(Boolean, default=False)
    valid_from: Mapped[dt.date | None] = mapped_column(Date, default=None)
    valid_to: Mapped[dt.date | None] = mapped_column(Date, default=None)
    min_nights: Mapped[int] = mapped_column(default=1)
    includes_breakfast: Mapped[bool] = mapped_column(Boolean, default=False)
    description: Mapped[str | None] = mapped_column(Text, default=None)


class RatePlanPrice(SyncBase):
    """Prix d'un plan tarifaire sur une periode et certains jours de semaine."""

    __tablename__ = "rate_plan_prices"
    __table_args__ = (
        Index("ix_rate_plan_prices_range", "rate_plan_id", "date_from", "date_to"),
        CheckConstraint("date_to >= date_from", name="date_range"),
    )

    rate_plan_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("rate_plans.id", ondelete="CASCADE")
    )
    date_from: Mapped[dt.date] = mapped_column(Date)
    date_to: Mapped[dt.date] = mapped_column(Date)
    # Masque binaire des jours concernes : bit 0 = lundi ... bit 6 = dimanche.
    # 127 = toute la semaine. Permet un tarif week-end sans dupliquer les lignes.
    weekday_mask: Mapped[int] = mapped_column(default=127)
    price: Mapped[int] = mapped_column(BigInteger)


class Tax(RefBase, HotelScoped):
    """Taxe applicable (TVA, taxe de sejour, taxe de promotion touristique)."""

    __tablename__ = "taxes"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(120))
    mode: Mapped[TaxMode] = mapped_column(_enum(TaxMode, "tax_mode"))
    # Taux en pourcentage, ou montant fixe selon `mode`.
    rate: Mapped[int] = mapped_column(Integer)
    # Categories de charges concernees, par exemple ["ROOM", "FNB"].
    applies_to: Mapped[dict | None] = mapped_column(JSONB, default=None)
    # Taxe deja comprise dans le prix affiche (TTC) ou ajoutee au moment de la
    # facturation (HT). Change entierement le calcul de la facture.
    is_included: Mapped[bool] = mapped_column(Boolean, default=True)
    sort_order: Mapped[int] = mapped_column(default=0)
