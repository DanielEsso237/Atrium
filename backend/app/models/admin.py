"""Parametrage, journee hoteliere, notifications."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    Boolean,
    Date,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import HotelScoped, SyncBase
from app.models.enums import BusinessDayStatus, SettingScope
from app.models.rooms import _enum


class Setting(SyncBase, HotelScoped):
    """Parametre applicatif.

    La portee permet de surcharger un reglage global pour une tablette donnee
    (imprimante par defaut, delai de verrouillage) ou pour un agent, sans
    dupliquer la configuration.
    """

    __tablename__ = "settings"
    __table_args__ = (UniqueConstraint("hotel_id", "key", "scope", "scope_id"),)

    key: Mapped[str] = mapped_column(String(80))
    value: Mapped[dict | None] = mapped_column(JSONB, default=None)
    scope: Mapped[SettingScope] = mapped_column(
        _enum(SettingScope, "setting_scope"), default=SettingScope.GLOBAL
    )
    scope_id: Mapped[uuid.UUID | None] = mapped_column(default=None)
    label: Mapped[str | None] = mapped_column(String(160), default=None)
    description: Mapped[str | None] = mapped_column(Text, default=None)


class BusinessDay(SyncBase, HotelScoped):
    """Journee hoteliere et sa cloture.

    La cloture fige les totaux dans `totals` plutot que de les laisser se
    recalculer : un chiffre d'affaires arrete ne doit plus bouger, meme si une
    facture de la veille est annulee le lendemain. C'est aussi ce qui rend les
    rapports du module Direction (F5.2) reproductibles a l'identique.
    """

    __tablename__ = "business_days"
    __table_args__ = (UniqueConstraint("hotel_id", "business_date"),)

    business_date: Mapped[dt.date] = mapped_column(Date, index=True)
    status: Mapped[BusinessDayStatus] = mapped_column(
        _enum(BusinessDayStatus, "business_day_status"), default=BusinessDayStatus.OPEN
    )
    opened_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    closed_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    closed_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    # Totaux figes : CA hebergement, CA restauration, taxes, encaissements par
    # mode de paiement, taux d'occupation, nombre d'arrivees et de departs.
    totals: Mapped[dict | None] = mapped_column(JSONB, default=None)
    notes: Mapped[str | None] = mapped_column(Text, default=None)


class Notification(SyncBase, HotelScoped):
    """Alerte destinee a un role ou a un agent.

    Porte notamment les alertes exigees par la regle R2 (imprimante hors ligne)
    et les rejets d'attribution de chambre issus de l'arbitrage serveur.
    """

    __tablename__ = "notifications"
    __table_args__ = (
        Index("ix_notifications_target_role", "target_role_id", "is_read"),
        Index("ix_notifications_target_user", "target_user_id", "is_read"),
    )

    kind: Mapped[str] = mapped_column(String(48), index=True)
    title: Mapped[str] = mapped_column(String(160))
    body: Mapped[str | None] = mapped_column(Text, default=None)
    severity: Mapped[str] = mapped_column(String(16), default="INFO")

    target_role_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("roles.id", ondelete="CASCADE"), default=None
    )
    target_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), default=None
    )
    entity_table: Mapped[str | None] = mapped_column(String(64), default=None)
    entity_id: Mapped[uuid.UUID | None] = mapped_column(default=None)

    is_read: Mapped[bool] = mapped_column(Boolean, default=False)
    read_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    read_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
