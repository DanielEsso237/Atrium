"""Service de mise en file d'impression (cahier des charges, paragraphe 4.2,

regles R1-R5).

Ce module ne parle a aucune imprimante physique -- ca, c'est le role d'un
agent/worker separe qui consommera la file `print_jobs` en statut QUEUED
(voir le commentaire du modele `PrintJob`). Ce service se limite a ce que le
serveur central peut faire seul : resoudre la bonne imprimante d'apres les
regles de routage (R5), et enregistrer le document a imprimer.
"""

from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import DocumentType, PrintJob, PrintRoute
from app.models.enums import PrintJobStatus


async def resolve_printer(
    session: AsyncSession,
    hotel_id: uuid.UUID,
    document_type_id: uuid.UUID,
    *,
    outlet_id: uuid.UUID | None = None,
    prep_station_id: uuid.UUID | None = None,
    device_id: uuid.UUID | None = None,
    role_id: uuid.UUID | None = None,
) -> uuid.UUID | None:
    """R5 : trouve l'imprimante a utiliser pour ce document dans ce contexte.

    Un critere de la regle laisse a NULL est un joker qui accepte n'importe
    quelle valeur de contexte ; entre plusieurs regles qui correspondent,
    `priority` la plus haute gagne (voir le modele `PrintRoute`).
    """
    result = await session.execute(
        select(PrintRoute)
        .where(
            PrintRoute.hotel_id == hotel_id,
            PrintRoute.document_type_id == document_type_id,
            PrintRoute.deleted_at.is_(None),
            (PrintRoute.match_outlet_id.is_(None)) | (PrintRoute.match_outlet_id == outlet_id),
            (PrintRoute.match_prep_station_id.is_(None))
            | (PrintRoute.match_prep_station_id == prep_station_id),
            (PrintRoute.match_device_id.is_(None)) | (PrintRoute.match_device_id == device_id),
            (PrintRoute.match_role_id.is_(None)) | (PrintRoute.match_role_id == role_id),
        )
        .order_by(PrintRoute.priority.desc())
        .limit(1)
    )
    route = result.scalar_one_or_none()
    return route.printer_id if route else None


async def enqueue_print_job(
    session: AsyncSession,
    hotel_id: uuid.UUID,
    document_type_code: str,
    payload: dict,
    *,
    outlet_id: uuid.UUID | None = None,
    prep_station_id: uuid.UUID | None = None,
    device_id: uuid.UUID | None = None,
    role_id: uuid.UUID | None = None,
    source_table: str | None = None,
    source_id: uuid.UUID | None = None,
    requested_by: uuid.UUID | None = None,
) -> PrintJob | None:
    """Cree un travail d'impression QUEUED si une regle de routage existe.

    Best-effort et silencieux en l'absence de type de document ou de regle :
    un ticket de cuisine qu'on ne sait pas router ne doit jamais faire
    echouer la commande qui l'a declenche -- l'impression est un effet de
    bord, pas une dependance bloquante des flux metier (reservation,
    facturation, commande). L'appelant peut inspecter la valeur de retour
    (`None` si rien n'a ete mis en file) s'il veut le signaler autrement.
    """
    doc_type = await session.scalar(
        select(DocumentType).where(
            DocumentType.hotel_id == hotel_id, DocumentType.code == document_type_code
        )
    )
    if doc_type is None:
        return None

    printer_id = await resolve_printer(
        session,
        hotel_id,
        doc_type.id,
        outlet_id=outlet_id,
        prep_station_id=prep_station_id,
        device_id=device_id,
        role_id=role_id,
    )
    if printer_id is None:
        return None

    job = PrintJob(
        hotel_id=hotel_id,
        document_type_id=doc_type.id,
        printer_id=printer_id,
        payload=payload,
        status=PrintJobStatus.QUEUED,
        source_table=source_table,
        source_id=source_id,
        requested_by=requested_by,
    )
    session.add(job)
    return job
