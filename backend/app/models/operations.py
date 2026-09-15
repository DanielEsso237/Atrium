"""Housekeeping et maintenance, plus les pieces jointes du terrain."""

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

from app.db.base import HotelScoped, RefBase, SyncBase
from app.models.enums import (
    HousekeepingTaskType,
    Priority,
    TaskStatus,
    TicketStatus,
    UploadState,
)
from app.models.rooms import _enum


class HousekeepingTask(SyncBase, HotelScoped):
    """Tache de nettoyage (F2.1, F2.2).

    Les horodatages de debut et de fin ne servent pas qu'au suivi : ils
    alimentent la duree moyenne par type de tache, seul moyen de dimensionner
    une equipe d'etage et d'alimenter les indicateurs de performance du
    module Direction (F5.1).
    """

    __tablename__ = "housekeeping_tasks"
    __table_args__ = (
        Index("ix_housekeeping_tasks_date_status", "business_date", "status"),
        Index("ix_housekeeping_tasks_assigned_to", "assigned_to"),
    )

    room_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("rooms.id", ondelete="CASCADE"), index=True
    )
    type: Mapped[HousekeepingTaskType] = mapped_column(
        _enum(HousekeepingTaskType, "housekeeping_task_type")
    )
    status: Mapped[TaskStatus] = mapped_column(
        _enum(TaskStatus, "task_status"), default=TaskStatus.PENDING
    )
    priority: Mapped[Priority] = mapped_column(
        _enum(Priority, "priority"), default=Priority.NORMAL
    )
    business_date: Mapped[dt.date] = mapped_column(Date)

    assigned_to: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    assigned_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    started_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    finished_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    duration_minutes: Mapped[int | None] = mapped_column(default=None)

    inspected_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    inspected_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    notes: Mapped[str | None] = mapped_column(Text, default=None)

    items: Mapped[list[HousekeepingTaskItem]] = relationship(
        back_populates="task", lazy="selectin"
    )


class HousekeepingTaskItem(SyncBase):
    """Point de controle d'une fiche de tache (imprimee, cf. F2.5)."""

    __tablename__ = "housekeeping_task_items"

    task_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("housekeeping_tasks.id", ondelete="CASCADE"), index=True
    )
    label: Mapped[str] = mapped_column(String(160))
    is_done: Mapped[bool] = mapped_column(Boolean, default=False)
    remark: Mapped[str | None] = mapped_column(String(255), default=None)
    sort_order: Mapped[int] = mapped_column(default=0)

    task: Mapped[HousekeepingTask] = relationship(back_populates="items")


class AmenityConsumption(SyncBase):
    """Consommables et linge utilises sur une tache (F2.4).

    Fait le pont entre le housekeeping et les stocks : chaque ligne genere un
    mouvement de sortie sur le magasin de l'etage.
    """

    __tablename__ = "amenity_consumptions"

    task_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("housekeeping_tasks.id", ondelete="CASCADE"), index=True
    )
    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="RESTRICT"), index=True
    )
    quantity: Mapped[int] = mapped_column(Integer, default=1)


class Equipment(RefBase, HotelScoped):
    """Equipement suivi : climatiseur, chauffe-eau, televiseur, ascenseur.

    Permet l'historique par equipement demande en F4.4, qui ne se deduit pas
    de l'historique par chambre : un climatiseur peut etre deplace, et un
    ascenseur n'appartient a aucune chambre.
    """

    __tablename__ = "equipments"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(160))
    category: Mapped[str | None] = mapped_column(String(64), default=None)
    room_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rooms.id", ondelete="SET NULL"), default=None, index=True
    )
    location: Mapped[str | None] = mapped_column(String(120), default=None)
    brand: Mapped[str | None] = mapped_column(String(80), default=None)
    model: Mapped[str | None] = mapped_column(String(80), default=None)
    serial_number: Mapped[str | None] = mapped_column(String(80), default=None)
    installed_at: Mapped[dt.date | None] = mapped_column(Date, default=None)
    warranty_until: Mapped[dt.date | None] = mapped_column(Date, default=None)
    supplier_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("suppliers.id", ondelete="SET NULL"), default=None
    )


class MaintenanceTicket(SyncBase, HotelScoped):
    """Signalement et intervention (F2.3, F4.1 a F4.4).

    `blocks_room` fait le lien avec `rooms.is_out_of_order` : ouvrir un ticket
    bloquant sort la chambre de la vente, le cloturer l'y remet. Sans ce lien
    explicite, une chambre reste hors service parce que personne ne pense a
    reactiver le drapeau apres reparation.
    """

    __tablename__ = "maintenance_tickets"
    __table_args__ = (
        UniqueConstraint("hotel_id", "number"),
        Index("ix_maintenance_tickets_status_priority", "status", "priority"),
        Index("ix_maintenance_tickets_assigned_to", "assigned_to"),
    )

    number: Mapped[str] = mapped_column(String(32))
    room_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rooms.id", ondelete="SET NULL"), default=None, index=True
    )
    equipment_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("equipments.id", ondelete="SET NULL"), default=None, index=True
    )
    location: Mapped[str | None] = mapped_column(String(120), default=None)
    category: Mapped[str | None] = mapped_column(String(64), default=None)

    title: Mapped[str] = mapped_column(String(160))
    description: Mapped[str | None] = mapped_column(Text, default=None)
    priority: Mapped[Priority] = mapped_column(
        _enum(Priority, "priority"), default=Priority.NORMAL
    )
    status: Mapped[TicketStatus] = mapped_column(
        _enum(TicketStatus, "ticket_status"), default=TicketStatus.OPEN
    )

    reported_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    reported_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    assigned_to: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    assigned_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    resolved_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    closed_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    resolution: Mapped[str | None] = mapped_column(Text, default=None)
    cost: Mapped[int] = mapped_column(BigInteger, default=0)
    blocks_room: Mapped[bool] = mapped_column(Boolean, default=False)

    interventions: Mapped[list[MaintenanceIntervention]] = relationship(
        back_populates="ticket", lazy="selectin"
    )


class MaintenanceIntervention(SyncBase):
    """Passage d'un technicien sur un ticket.

    Un ticket peut demander plusieurs passages (diagnostic, commande de piece,
    reparation). Les tracer separement donne le temps reellement passe et le
    cout des pieces, que le seul ticket ne permet pas de reconstituer.
    """

    __tablename__ = "maintenance_interventions"

    ticket_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("maintenance_tickets.id", ondelete="CASCADE"), index=True
    )
    technician_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    started_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    ended_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    description: Mapped[str | None] = mapped_column(Text, default=None)
    parts_used: Mapped[dict | None] = mapped_column(JSONB, default=None)
    cost: Mapped[int] = mapped_column(BigInteger, default=0)

    ticket: Mapped[MaintenanceTicket] = relationship(back_populates="interventions")


class Attachment(SyncBase):
    """Piece jointe generique : photo de panne, document, rapport.

    Meme principe que `signatures` : le fichier existe d'abord sur la tablette,
    puis recoit une URL serveur. `upload_state` est suivi par un worker distinct
    de la synchronisation des lignes metier, parce qu'une photo de 3 Mo prise
    dans un couloir sans reseau ne doit pas bloquer la remontee d'un ticket
    urgent qui, lui, ne pese que quelques centaines d'octets.
    """

    __tablename__ = "attachments"
    __table_args__ = (
        Index("ix_attachments_entity", "entity_table", "entity_id"),
        Index("ix_attachments_upload_state", "upload_state"),
    )

    entity_table: Mapped[str] = mapped_column(String(64))
    entity_id: Mapped[uuid.UUID] = mapped_column()
    kind: Mapped[str] = mapped_column(String(32), default="PHOTO")
    file_path_local: Mapped[str | None] = mapped_column(String(255), default=None)
    file_url: Mapped[str | None] = mapped_column(String(512), default=None)
    mime_type: Mapped[str | None] = mapped_column(String(80), default=None)
    size_bytes: Mapped[int | None] = mapped_column(default=None)
    upload_state: Mapped[UploadState] = mapped_column(
        _enum(UploadState, "upload_state"), default=UploadState.PENDING
    )
    caption: Mapped[str | None] = mapped_column(String(255), default=None)
    captured_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    captured_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
