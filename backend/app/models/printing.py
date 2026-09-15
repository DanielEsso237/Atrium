"""Impression localisee : imprimantes, routage, modeles, file d'attente.

C'est le coeur du projet (paragraphe 4.2 du cahier des charges). Les cinq
regles de routage y sont traduites en structures de donnees :

  R1  cuisine != bar        -> `order_items.prep_station_id` -> `print_routes`
  R2  hors ligne -> file    -> `print_jobs.status` + `printers.is_online`
  R3  reimpression          -> `print_jobs.is_duplicate` + `original_job_id`
  R4  nom logique           -> `printers.logical_name`
  R5  routage configurable  -> `print_routes`, editable depuis l'administration
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    Boolean,
    ForeignKey,
    Index,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import HotelScoped, RefBase, SyncBase
from app.models.enums import (
    PrinterKind,
    PrinterProtocol,
    PrintJobStatus,
    TemplateFormat,
)
from app.models.rooms import _enum


class Printer(RefBase, HotelScoped):
    """Imprimante physique, designee par un nom logique (regle R4).

    L'application ne manipule jamais une adresse IP : elle demande
    `IMP_CUISINE_01`. Remplacer une imprimante en panne revient alors a changer
    une ligne de configuration, sans toucher au code ni aux tablettes.
    """

    __tablename__ = "printers"
    __table_args__ = (UniqueConstraint("hotel_id", "logical_name"),)

    logical_name: Mapped[str] = mapped_column(String(64))
    label: Mapped[str] = mapped_column(String(120))
    kind: Mapped[PrinterKind] = mapped_column(_enum(PrinterKind, "printer_kind"))
    protocol: Mapped[PrinterProtocol] = mapped_column(
        _enum(PrinterProtocol, "printer_protocol")
    )
    host: Mapped[str | None] = mapped_column(String(120), default=None)
    port: Mapped[int | None] = mapped_column(default=None)
    device_path: Mapped[str | None] = mapped_column(String(255), default=None)
    # Largeur du papier thermique, en millimetres : 58 ou 80 en pratique.
    # Conditionne le nombre de caracteres par ligne du modele ESC/POS.
    paper_width_mm: Mapped[int | None] = mapped_column(default=None)
    location: Mapped[str | None] = mapped_column(String(120), default=None)
    prep_station_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("prep_stations.id", ondelete="SET NULL"), default=None, index=True
    )

    # Supervision (regle R2) : sans heartbeat, on ne decouvre qu'une imprimante
    # est hors ligne qu'au moment ou un ticket est deja perdu.
    is_online: Mapped[bool] = mapped_column(Boolean, default=False)
    last_heartbeat_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    last_error: Mapped[str | None] = mapped_column(String(255), default=None)
    # Repli automatique quand la cible est injoignable.
    fallback_printer_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("printers.id", ondelete="SET NULL"), default=None
    )


class DocumentType(RefBase, HotelScoped):
    """Nature de document imprimable, reprise de la matrice du paragraphe 4.2."""

    __tablename__ = "document_types"
    __table_args__ = (UniqueConstraint("hotel_id", "code"),)

    code: Mapped[str] = mapped_column(String(48))
    label: Mapped[str] = mapped_column(String(120))
    default_kind: Mapped[PrinterKind] = mapped_column(
        _enum(PrinterKind, "printer_kind"), default=PrinterKind.LASER
    )
    # Nombre d'exemplaires a imprimer par defaut (souche + client).
    copies: Mapped[int] = mapped_column(default=1)
    allow_reprint: Mapped[bool] = mapped_column(Boolean, default=True)


class PrintRoute(RefBase, HotelScoped):
    """Regle de routage (regle R5).

    Resolution : parmi les regles actives du type de document, on retient celle
    de plus forte priorite dont tous les criteres renseignes correspondent au
    contexte. Un critere laisse a NULL est un joker.

    Cette table est editable depuis l'administration, ce qui evite de livrer
    une nouvelle version de l'application chaque fois que l'hotel deplace une
    imprimante ou ouvre un nouveau point de vente.
    """

    __tablename__ = "print_routes"
    __table_args__ = (Index("ix_print_routes_lookup", "document_type_id", "priority"),)

    document_type_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("document_types.id", ondelete="CASCADE"), index=True
    )
    printer_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("printers.id", ondelete="RESTRICT"), index=True
    )

    match_outlet_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("outlets.id", ondelete="CASCADE"), default=None
    )
    match_prep_station_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("prep_stations.id", ondelete="CASCADE"), default=None
    )
    match_device_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("devices.id", ondelete="CASCADE"), default=None
    )
    match_role_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("roles.id", ondelete="CASCADE"), default=None
    )
    # Priorite decroissante : la premiere regle qui correspond l'emporte.
    priority: Mapped[int] = mapped_column(default=0)
    label: Mapped[str | None] = mapped_column(String(120), default=None)


class DocumentTemplate(RefBase, HotelScoped):
    """Modele de document, versionne.

    Le versionnage sert la reimpression : reimprimer une facture de l'an
    dernier doit reproduire la mise en page de l'epoque, pas celle d'aujourd'hui.
    """

    __tablename__ = "document_templates"
    __table_args__ = (UniqueConstraint("document_type_id", "version"),)

    document_type_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("document_types.id", ondelete="CASCADE"), index=True
    )
    version: Mapped[int] = mapped_column(default=1)
    format: Mapped[TemplateFormat] = mapped_column(
        _enum(TemplateFormat, "template_format")
    )
    content: Mapped[str] = mapped_column(Text)
    label: Mapped[str | None] = mapped_column(String(120), default=None)


class PrintJob(SyncBase, HotelScoped):
    """Travail d'impression, du declenchement a la sortie papier.

    Cette table vit aussi sur les tablettes : c'est la file d'attente exigee au
    paragraphe 6.3. Un ticket cree pendant une coupure Wi-Fi est enregistre
    localement en QUEUED et part a la reconnexion -- il n'est jamais perdu.

    `payload` conserve les donnees du document plutot qu'une simple reference a
    la commande : un ticket de cuisine doit pouvoir etre reimprime a l'identique
    meme si la commande a ete modifiee depuis.
    """

    __tablename__ = "print_jobs"
    __table_args__ = (
        Index("ix_print_jobs_status_created", "status", "created_at"),
        Index("ix_print_jobs_printer_status", "printer_id", "status"),
        Index("ix_print_jobs_source", "source_table", "source_id"),
    )

    document_type_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("document_types.id", ondelete="RESTRICT"), index=True
    )
    printer_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("printers.id", ondelete="SET NULL"), default=None
    )
    template_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("document_templates.id", ondelete="SET NULL"), default=None
    )

    payload: Mapped[dict | None] = mapped_column(JSONB, default=None)
    # Document deja mis en forme (flux ESC/POS ou PDF), quand il a ete rendu.
    rendered: Mapped[bytes | None] = mapped_column(LargeBinary, default=None)

    status: Mapped[PrintJobStatus] = mapped_column(
        _enum(PrintJobStatus, "print_job_status"), default=PrintJobStatus.QUEUED
    )
    attempts: Mapped[int] = mapped_column(default=0)
    last_error: Mapped[str | None] = mapped_column(String(255), default=None)

    # Regle R3 : une reimpression est un nouveau travail marque DUPLICATA et
    # relie a l'original, jamais une reexecution silencieuse du premier.
    is_duplicate: Mapped[bool] = mapped_column(Boolean, default=False)
    original_job_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("print_jobs.id", ondelete="SET NULL"), default=None
    )

    source_table: Mapped[str | None] = mapped_column(String(64), default=None)
    source_id: Mapped[uuid.UUID | None] = mapped_column(default=None)
    requested_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    requested_from_device_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("devices.id", ondelete="SET NULL"), default=None
    )
    sent_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    printed_at: Mapped[dt.datetime | None] = mapped_column(default=None)
