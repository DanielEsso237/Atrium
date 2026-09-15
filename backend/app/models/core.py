"""Socle : etablissement, utilisateurs, roles, permissions, terminaux, audit."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    Boolean,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import INET, JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import (
    Base,
    HotelScoped,
    RefBase,
    RootBase,
    ServerBase,
    SyncBase,
    UUIDPrimaryKey,
)


class Hotel(RootBase):
    """L'etablissement.

    Le projet demarre avec une seule ligne ici. La table existe quand meme pour
    que le passage a un groupe hotelier ne soit pas une refonte : les colonnes
    `hotel_id` sont deja en place partout.
    """

    __tablename__ = "hotels"

    code: Mapped[str] = mapped_column(String(16), unique=True)
    name: Mapped[str] = mapped_column(String(160))
    legal_name: Mapped[str | None] = mapped_column(String(160), default=None)
    address: Mapped[str | None] = mapped_column(String(255), default=None)
    city: Mapped[str | None] = mapped_column(String(80), default=None)
    postal_code: Mapped[str | None] = mapped_column(String(20), default=None)
    country: Mapped[str | None] = mapped_column(String(80), default=None)
    phone: Mapped[str | None] = mapped_column(String(40), default=None)
    email: Mapped[str | None] = mapped_column(String(160), default=None)
    website: Mapped[str | None] = mapped_column(String(160), default=None)
    tax_id: Mapped[str | None] = mapped_column(String(40), default=None)
    logo_path: Mapped[str | None] = mapped_column(String(255), default=None)
    timezone: Mapped[str] = mapped_column(String(64), default="Africa/Abidjan")
    currency: Mapped[str] = mapped_column(String(8), default="XOF")
    # Heure de bascule du jour hotelier : le "CA JOUR" du tableau de bord se
    # calcule sur cette journee-la, pas sur minuit-minuit.
    day_rollover_hour: Mapped[int] = mapped_column(default=6)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)


class Role(RefBase):
    __tablename__ = "roles"

    code: Mapped[str] = mapped_column(String(32), unique=True)
    label: Mapped[str] = mapped_column(String(80))
    description: Mapped[str | None] = mapped_column(Text, default=None)
    # Un role systeme ne peut etre ni renomme ni supprime depuis l'admin.
    is_system: Mapped[bool] = mapped_column(Boolean, default=False)
    # Ecran d'accueil apres connexion : le cahier des charges prevoit une seule
    # application dont l'interface change selon le role (paragraphe 3.4).
    home_route: Mapped[str | None] = mapped_column(String(80), default=None)

    permissions: Mapped[list[Permission]] = relationship(
        secondary="role_permissions", back_populates="roles", lazy="selectin"
    )


class Permission(UUIDPrimaryKey, Base):
    """Permission atomique, par exemple `folio.discount` ou `print.reprint`.

    Referentiel fige, livre avec l'application : pas de colonnes de
    synchronisation, il est pousse par les migrations et non par la sync.
    """

    __tablename__ = "permissions"

    code: Mapped[str] = mapped_column(String(64), unique=True)
    label: Mapped[str] = mapped_column(String(120))
    module: Mapped[str] = mapped_column(String(32), index=True)

    roles: Mapped[list[Role]] = relationship(
        secondary="role_permissions", back_populates="permissions"
    )


class RolePermission(Base):
    __tablename__ = "role_permissions"

    role_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("roles.id", ondelete="CASCADE"), primary_key=True
    )
    permission_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("permissions.id", ondelete="CASCADE"), primary_key=True
    )


class User(SyncBase, HotelScoped):
    """Membre du personnel."""

    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("hotel_id", "employee_code"),
        Index("ix_users_badge_code", "badge_code"),
    )

    employee_code: Mapped[str] = mapped_column(String(32))
    first_name: Mapped[str] = mapped_column(String(80))
    last_name: Mapped[str] = mapped_column(String(80))
    email: Mapped[str | None] = mapped_column(String(160), default=None, unique=True)
    phone: Mapped[str | None] = mapped_column(String(40), default=None)
    photo_path: Mapped[str | None] = mapped_column(String(255), default=None)

    # Trois voies d'authentification (exigence 6.2), toutes hachees :
    #  - mot de passe pour l'administration et les postes fixes ;
    #  - code PIN pour la bascule rapide d'un agent a l'autre sur une meme
    #    tablette en mode kiosque ;
    #  - badge pour les equipes de terrain (housekeeping, maintenance).
    password_hash: Mapped[str | None] = mapped_column(String(255), default=None)
    pin_hash: Mapped[str | None] = mapped_column(String(255), default=None)
    badge_code: Mapped[str | None] = mapped_column(String(64), default=None)

    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    must_change_password: Mapped[bool] = mapped_column(Boolean, default=True)
    last_login_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    failed_login_count: Mapped[int] = mapped_column(default=0)
    locked_until: Mapped[dt.datetime | None] = mapped_column(default=None)
    language: Mapped[str] = mapped_column(String(8), default="fr")

    roles: Mapped[list[Role]] = relationship(
        secondary="user_roles", lazy="selectin", viewonly=True
    )

    @property
    def full_name(self) -> str:
        return f"{self.first_name} {self.last_name}".strip()


class UserRole(Base):
    __tablename__ = "user_roles"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    role_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("roles.id", ondelete="CASCADE"), primary_key=True
    )


class Device(SyncBase, HotelScoped):
    """Tablette ou poste enregistre.

    L'identite du terminal est de premiere importance ici : elle determine
    l'imprimante cible par defaut (routage du paragraphe 4.2), elle borne le
    perimetre replique, et elle permet de tracer quelle tablette a produit une
    ecriture lors d'un conflit de synchronisation.
    """

    __tablename__ = "devices"
    __table_args__ = (UniqueConstraint("device_uid"),)

    device_uid: Mapped[str] = mapped_column(String(128))
    name: Mapped[str] = mapped_column(String(80))
    location: Mapped[str | None] = mapped_column(String(120), default=None)
    default_role_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("roles.id", ondelete="SET NULL"), default=None
    )
    default_outlet_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("outlets.id", ondelete="SET NULL"), default=None
    )
    default_printer_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("printers.id", ondelete="SET NULL"), default=None
    )

    is_kiosk: Mapped[bool] = mapped_column(Boolean, default=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    os_version: Mapped[str | None] = mapped_column(String(40), default=None)
    app_version: Mapped[str | None] = mapped_column(String(20), default=None)
    last_seen_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    last_sync_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    # Verrouillage automatique apres inactivite (exigence 6.2).
    auto_lock_seconds: Mapped[int] = mapped_column(default=300)


class RefreshToken(ServerBase):
    """Jeton de rafraichissement. Ne quitte jamais le serveur."""

    __tablename__ = "refresh_tokens"
    __table_args__ = (Index("ix_refresh_tokens_user_device", "user_id", "device_id"),)

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE")
    )
    device_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("devices.id", ondelete="CASCADE"), default=None
    )
    token_hash: Mapped[str] = mapped_column(String(255), unique=True)
    expires_at: Mapped[dt.datetime] = mapped_column()
    revoked_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    user_agent: Mapped[str | None] = mapped_column(String(255), default=None)


class AuditLog(ServerBase):
    """Journal d'audit (exigence 6.2 : journalisation de toutes les actions).

    Reste sur le serveur central : le repliquer sur les tablettes multiplierait
    le volume transfere sans aucun usage cote terrain, et affaiblirait la piste
    d'audit en la rendant modifiable hors ligne.
    """

    __tablename__ = "audit_logs"
    __table_args__ = (
        Index("ix_audit_logs_entity", "entity_table", "entity_id"),
        Index("ix_audit_logs_occurred_at", "occurred_at"),
    )

    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    device_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("devices.id", ondelete="SET NULL"), default=None
    )
    entity_table: Mapped[str] = mapped_column(String(64))
    entity_id: Mapped[uuid.UUID | None] = mapped_column(default=None)
    action: Mapped[str] = mapped_column(String(64))
    before: Mapped[dict | None] = mapped_column(JSONB, default=None)
    after: Mapped[dict | None] = mapped_column(JSONB, default=None)
    ip_address: Mapped[str | None] = mapped_column(INET, default=None)
    occurred_at: Mapped[dt.datetime] = mapped_column()
