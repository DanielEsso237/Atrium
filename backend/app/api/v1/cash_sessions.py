"""Routes sessions de caisse : ouverture, consultation, fermeture (role Caissier).

Une session par caissier a la fois (index unique partiel en base). Les
encaissements en especes enregistres pendant la session s'y rattachent
(`payments.cash_session_id`, voir app/api/v1/billing.py) ; a la fermeture,
l'attendu est recalcule depuis ces paiements et compare au comptage physique.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import case, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import CashSession, Device, Payment, User
from app.models.enums import CashSessionStatus, PaymentMethod
from app.schemas.cash_sessions import CashSessionCloseIn, CashSessionOpenIn, CashSessionOut
from app.services.printing import enqueue_print_job

router = APIRouter(prefix="/cash-sessions", tags=["caisse"])


async def open_session_id(session: AsyncSession, user: User) -> uuid.UUID | None:
    """Session ouverte de l'utilisateur, s'il en a une (une seule possible)."""
    return await session.scalar(
        select(CashSession.id).where(
            CashSession.user_id == user.id,
            CashSession.status == CashSessionStatus.OPEN,
            CashSession.deleted_at.is_(None),
        )
    )


async def _expected_cash(session: AsyncSession, cash_session: CashSession) -> int:
    """Fond de caisse + especes encaissees - especes remboursees."""
    cash_in = await session.scalar(
        select(
            func.coalesce(
                func.sum(case((Payment.is_refund, -Payment.amount), else_=Payment.amount)), 0
            )
        ).where(
            Payment.cash_session_id == cash_session.id,
            Payment.method == PaymentMethod.CASH,
            Payment.deleted_at.is_(None),
        )
    )
    # SUM(bigint) renvoie un numeric (Decimal) : int() pour les montants
    # entiers du projet et pour la serialisation JSON du rapport de shift.
    return cash_session.opening_float + int(cash_in or 0)


@router.post("", response_model=CashSessionOut, status_code=status.HTTP_201_CREATED)
async def open_cash_session(
    payload: CashSessionOpenIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("cash.session")),
) -> CashSession:
    if await open_session_id(session, user) is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Une session de caisse est deja ouverte.")
    if payload.device_id is not None:
        device = await session.get(Device, payload.device_id)
        if device is None or device.hotel_id != user.hotel_id or device.deleted_at is not None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Appareil inconnu.")

    cash_session = CashSession(
        hotel_id=user.hotel_id,
        user_id=user.id,
        device_id=payload.device_id,
        status=CashSessionStatus.OPEN,
        opened_at=dt.datetime.now(dt.timezone.utc),
        opening_float=payload.opening_float,
        expected_amount=payload.opening_float,
        notes=payload.notes,
    )
    session.add(cash_session)
    try:
        await session.commit()
    except IntegrityError as exc:
        # Deux ouvertures simultanees : l'index unique partiel a tranche.
        await session.rollback()
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Une session de caisse est deja ouverte."
        ) from exc
    await session.refresh(cash_session)
    return cash_session


@router.get("/current", response_model=CashSessionOut)
async def current_cash_session(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("cash.session")),
) -> CashSession:
    session_id = await open_session_id(session, user)
    if session_id is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Aucune session de caisse ouverte.")
    cash_session = await session.get(CashSession, session_id)
    cash_session.expected_amount = await _expected_cash(session, cash_session)
    return cash_session


@router.post("/{session_id}/close", response_model=CashSessionOut)
async def close_cash_session(
    session_id: uuid.UUID,
    payload: CashSessionCloseIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("cash.session")),
) -> CashSession:
    """Fermeture : comptage physique, attendu recalcule, ecart = compte - attendu.

    Seul le titulaire ferme sa session. La ligne est verrouillee : un paiement
    ne peut pas s'y rattacher pendant qu'on calcule l'attendu (voir
    `record_payment`, qui verrouille la meme ligne).
    """
    cash_session = await session.scalar(
        select(CashSession)
        .where(
            CashSession.id == session_id,
            CashSession.hotel_id == user.hotel_id,
            CashSession.deleted_at.is_(None),
        )
        .with_for_update()
    )
    if cash_session is None or cash_session.user_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Session de caisse introuvable.")
    if cash_session.status != CashSessionStatus.OPEN:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cette session est deja fermee.")

    expected = await _expected_cash(session, cash_session)
    cash_session.status = CashSessionStatus.CLOSED
    cash_session.closed_at = dt.datetime.now(dt.timezone.utc)
    cash_session.counted_amount = payload.counted_amount
    cash_session.expected_amount = expected
    cash_session.variance = payload.counted_amount - expected
    if payload.notes:
        cash_session.notes = payload.notes

    # Rapport de shift (matrice d'impression, paragraphe 4.2). Best-effort,
    # comme toute impression : sans regle de routage, la fermeture passe.
    await enqueue_print_job(
        session,
        user.hotel_id,
        "SHIFT_REPORT",
        payload={
            "cashier": user.full_name,
            "opened_at": cash_session.opened_at.isoformat() if cash_session.opened_at else None,
            "closed_at": cash_session.closed_at.isoformat(),
            "opening_float": cash_session.opening_float,
            "expected_amount": expected,
            "counted_amount": payload.counted_amount,
            "variance": cash_session.variance,
        },
        source_table="cash_sessions",
        source_id=cash_session.id,
        requested_by=user.id,
    )

    await session.commit()
    await session.refresh(cash_session)
    return cash_session
