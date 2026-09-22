"""Routes file d'impression : consultation par un futur agent d'impression,

reimpression manuelle (regle R3)."""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import PrintJob, User
from app.models.enums import PrintJobStatus
from app.schemas.print_jobs import FailIn, PrintJobOut

router = APIRouter(prefix="/print-jobs", tags=["impression"])


async def _get_job(session: AsyncSession, job_id: uuid.UUID, user: User) -> PrintJob:
    job = await session.get(PrintJob, job_id)
    if job is None or job.hotel_id != user.hotel_id or job.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Travail d'impression introuvable.")
    return job


@router.get("", response_model=list[PrintJobOut])
async def list_print_jobs(
    status_filter: PrintJobStatus | None = Query(None, alias="status"),
    printer_id: uuid.UUID | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.read")),
) -> list[PrintJob]:
    """C'est cette route qu'un agent d'impression interrogerait en boucle

    (`?status=QUEUED&printer_id=...`) pour savoir quoi envoyer -- personne ne
    l'a encore ecrit, mais l'API qu'il consommerait existe des maintenant.
    """
    stmt = select(PrintJob).where(PrintJob.hotel_id == user.hotel_id, PrintJob.deleted_at.is_(None))
    if status_filter:
        stmt = stmt.where(PrintJob.status == status_filter)
    if printer_id:
        stmt = stmt.where(PrintJob.printer_id == printer_id)
    stmt = stmt.order_by(PrintJob.created_at)
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.get("/{job_id}", response_model=PrintJobOut)
async def get_print_job(
    job_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.read")),
) -> PrintJob:
    return await _get_job(session, job_id, user)


@router.post("/{job_id}/mark-sent", response_model=PrintJobOut)
async def mark_sent(
    job_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.write")),
) -> PrintJob:
    job = await _get_job(session, job_id, user)
    job.status = PrintJobStatus.SENT
    job.sent_at = dt.datetime.now(dt.timezone.utc)
    job.attempts += 1
    await session.commit()
    await session.refresh(job)
    return job


@router.post("/{job_id}/mark-printed", response_model=PrintJobOut)
async def mark_printed(
    job_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.write")),
) -> PrintJob:
    job = await _get_job(session, job_id, user)
    job.status = PrintJobStatus.PRINTED
    job.printed_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()
    await session.refresh(job)
    return job


@router.post("/{job_id}/mark-failed", response_model=PrintJobOut)
async def mark_failed(
    job_id: uuid.UUID,
    payload: FailIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.write")),
) -> PrintJob:
    job = await _get_job(session, job_id, user)
    job.status = PrintJobStatus.FAILED
    job.last_error = payload.error
    job.attempts += 1
    await session.commit()
    await session.refresh(job)
    return job


@router.post(
    "/{job_id}/reprint", response_model=PrintJobOut, status_code=status.HTTP_201_CREATED
)
async def reprint(
    job_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("print.reprint")),
) -> PrintJob:
    """Regle R3 : une reimpression est un **nouveau** travail marque

    duplicata et relie a l'original, jamais une reexecution silencieuse du
    premier -- on garde ainsi la trace de qui a redemande quoi et quand.
    """
    original = await _get_job(session, job_id, user)
    duplicate = PrintJob(
        hotel_id=user.hotel_id,
        document_type_id=original.document_type_id,
        printer_id=original.printer_id,
        payload=original.payload,
        status=PrintJobStatus.QUEUED,
        is_duplicate=True,
        original_job_id=original.id,
        source_table=original.source_table,
        source_id=original.source_id,
        requested_by=user.id,
    )
    session.add(duplicate)
    await session.commit()
    await session.refresh(duplicate)
    return duplicate
