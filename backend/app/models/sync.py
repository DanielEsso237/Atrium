"""Synchronisation : journal de changements, curseurs, conflits, numerotation.

Ces tables restent sur le serveur central. Leurs equivalents cote tablette
(outbox, curseurs locaux, file de televersement) vivent dans le schema Drift.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    BigInteger,
    ForeignKey,
    Index,
    Sequence,
    String,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, ServerBase, UUIDPrimaryKey
from app.models.enums import ConflictResolution, SyncOp
from app.models.rooms import _enum

# Sequence unique a toute la base : c'est elle qui alimente `change_seq` sur
# chaque table metier. Une sequence par table ne conviendrait pas -- il faut un
# ordre total entre les modifications pour qu'un client puisse reprendre une
# synchronisation interrompue sans trou ni doublon.
SYNC_SEQUENCE = Sequence("sync_seq", metadata=Base.metadata)


class SyncChangeLog(UUIDPrimaryKey, Base):
    """Journal des modifications, alimente par trigger.

    Sert deux besoins que `change_seq` seul ne couvre pas : propager les
    suppressions definitives (purge) et fournir a une tablette longtemps
    deconnectee la liste exacte de ce qu'elle a manque.
    """

    __tablename__ = "sync_change_log"
    __table_args__ = (
        Index("ix_sync_change_log_table_seq", "entity_table", "seq"),
        Index("ix_sync_change_log_changed_at", "changed_at"),
    )

    # Alimente par le trigger `atrium_track_change`, avec la meme valeur que
    # le `change_seq` de la ligne concernee : les deux doivent designer le
    # meme point dans l'ordre total des modifications.
    seq: Mapped[int] = mapped_column(BigInteger, unique=True, index=True)
    entity_table: Mapped[str] = mapped_column(String(64))
    entity_id: Mapped[uuid.UUID] = mapped_column()
    op: Mapped[SyncOp] = mapped_column(_enum(SyncOp, "sync_op"))
    changed_at: Mapped[dt.datetime] = mapped_column()
    changed_by_device_id: Mapped[uuid.UUID | None] = mapped_column(default=None)
    payload: Mapped[dict | None] = mapped_column(JSONB, default=None)


class SyncDeviceCursor(ServerBase):
    """Ou en est chaque tablette, table par table.

    Permet de superviser la flotte : une tablette dont le curseur stagne est
    hors service ou hors reseau, et il vaut mieux le voir depuis
    l'administration que l'apprendre par la reception.
    """

    __tablename__ = "sync_device_cursors"
    __table_args__ = (UniqueConstraint("device_id", "entity_table"),)

    device_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("devices.id", ondelete="CASCADE"), index=True
    )
    entity_table: Mapped[str] = mapped_column(String(64))
    last_seq_pulled: Mapped[int] = mapped_column(BigInteger, default=0)
    last_pull_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    last_push_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    pending_count: Mapped[int] = mapped_column(default=0)


class SyncConflict(ServerBase):
    """Conflit detecte lors d'un push.

    Les conflits ne sont pas tous resolus automatiquement. L'attribution d'une
    chambre en est l'exemple : deux receptions hors ligne peuvent attribuer la
    205 au meme moment, et aucune regle automatique n'est acceptable. Le serveur
    tranche, rejette le perdant, et la ligne reste ici en PENDING jusqu'a ce
    qu'un humain la traite -- avec une notification a la reception.
    """

    __tablename__ = "sync_conflicts"
    __table_args__ = (
        Index("ix_sync_conflicts_entity", "entity_table", "entity_id"),
        Index("ix_sync_conflicts_resolution", "resolution"),
    )

    entity_table: Mapped[str] = mapped_column(String(64))
    entity_id: Mapped[uuid.UUID] = mapped_column()
    device_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("devices.id", ondelete="SET NULL"), default=None
    )
    client_payload: Mapped[dict | None] = mapped_column(JSONB, default=None)
    server_payload: Mapped[dict | None] = mapped_column(JSONB, default=None)
    resolution: Mapped[ConflictResolution] = mapped_column(
        _enum(ConflictResolution, "conflict_resolution"),
        default=ConflictResolution.PENDING,
    )
    reason: Mapped[str | None] = mapped_column(String(255), default=None)
    resolved_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    resolved_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    detected_at: Mapped[dt.datetime | None] = mapped_column(default=None)


class NumberSequence(ServerBase):
    """Compteurs de numerotation, attribues exclusivement par le serveur.

    Une numerotation legale de factures doit etre continue et sans trou. Aucune
    tablette isolee ne peut le garantir : c'est pourquoi une facture emise hors
    ligne reste provisoire et ne recoit son numero definitif qu'ici, au moment
    de la synchronisation.

    `period` permet une remise a zero annuelle ou mensuelle selon les usages
    comptables de l'etablissement.
    """

    __tablename__ = "number_sequences"
    __table_args__ = (UniqueConstraint("hotel_id", "scope", "period"),)

    hotel_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("hotels.id", ondelete="CASCADE"), index=True
    )
    scope: Mapped[str] = mapped_column(String(32))
    # Periode de remise a zero : "2026", "2026-09", ou "ALL" si jamais remise.
    period: Mapped[str] = mapped_column(String(16), default="ALL")
    prefix: Mapped[str | None] = mapped_column(String(16), default=None)
    padding: Mapped[int] = mapped_column(default=5)
    current_value: Mapped[int] = mapped_column(BigInteger, default=0)


class SyncedTable(UUIDPrimaryKey, Base):
    """Registre des tables repliquees et de leur politique.

    Rend le moteur de synchronisation pilote par la donnee : ajouter une table
    repliquee revient a inserer une ligne ici, sans toucher au code du moteur.
    """

    __tablename__ = "synced_tables"

    entity_table: Mapped[str] = mapped_column(String(64), unique=True)
    # Ordre d'application au push et au pull, pour respecter les dependances de
    # cles etrangeres (les chambres avant les reservations, par exemple).
    sync_order: Mapped[int] = mapped_column(default=100)
    # LWW, STATE_MACHINE ou SERVER_AUTHORITATIVE : les trois politiques du
    # paragraphe 10 de docs/01-modele-de-donnees.md.
    conflict_policy: Mapped[str] = mapped_column(String(32), default="LWW")
    # Fenetre glissante repliquee, en jours. NULL = tout l'historique
    # (referentiels : chambres, produits, menu).
    window_days: Mapped[int | None] = mapped_column(default=None)
    # Colonne de date servant a borner la fenetre glissante.
    window_column: Mapped[str | None] = mapped_column(String(64), default=None)
    is_push_allowed: Mapped[bool] = mapped_column(default=True)
