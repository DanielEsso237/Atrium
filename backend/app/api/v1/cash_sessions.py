"""Routes sessions de caisse : ouverture, consultation, fermeture (role Caissier).

Une session par caissier a la fois (index unique partiel en base). Les
encaissements en especes enregistres pendant la session s'y rattachent
(`payments.cash_session_id`, voir app/api/v1/billing.py) ; a la fermeture,
l'attendu est recalcule depuis ces paiements et compare au comptage physique.

**La reception est la caisse centrale.** La caisse d'un point de vente porte
son `outlet_id` ; sa fermeture est le versement du soir -- le montant compte
est celui que l'agent declare remettre -- et la reception confirme ensuite ce
qu'elle recoit (`POST /cash-sessions/{id}/receive`). Le versement recu entre
dans la caisse ouverte de celui qui le recoit, et gonfle son attendu.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import and_, case, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import permission_codes, require_permission
from app.db.session import get_session
from app.models import CashSession, Device, Outlet, Payment, User
from app.models.enums import CashSessionStatus, PaymentMethod
from app.schemas.cash_sessions import (
    CashSessionCloseIn,
    CashSessionOpenIn,
    CashSessionOut,
    CashSessionReceiveIn,
)
from app.services.printing import enqueue_print_job

# Tenir la caisse centrale : voir les caisses des points de vente et
# confirmer leurs versements.
CENTRAL = "cash.central"

router = APIRouter(prefix="/cash-sessions", tags=["caisse"])


async def open_session_id(
    session: AsyncSession, user: User, *, for_update: bool = False
) -> uuid.UUID | None:
    """Session ouverte de l'utilisateur, s'il en a une (une seule possible).

    `for_update` verrouille la session : un encaissement ne doit pas s'y
    rattacher pendant qu'une fermeture calcule l'attendu.
    """
    stmt = select(CashSession.id).where(
        CashSession.user_id == user.id,
        CashSession.status == CashSessionStatus.OPEN,
        CashSession.deleted_at.is_(None),
    )
    if for_update:
        stmt = stmt.with_for_update()
    return await session.scalar(stmt)


async def _expected_cash(session: AsyncSession, cash_session: CashSession) -> int:
    """Fond de caisse + especes encaissees - especes remboursees + versements recus."""
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
    # Les versements des points de vente confirmes dans cette caisse : des
    # especes entrees dans le tiroir, au meme titre qu'un encaissement. Les
    # oublier ferait constater un excedent a chaque fermeture de la reception.
    remitted = await session.scalar(
        select(func.coalesce(func.sum(CashSession.received_amount), 0)).where(
            CashSession.received_session_id == cash_session.id,
            CashSession.deleted_at.is_(None),
        )
    )
    # SUM(bigint) renvoie un numeric (Decimal) : int() pour les montants
    # entiers du projet et pour la serialisation JSON du rapport de shift.
    return cash_session.opening_float + int(cash_in or 0) + int(remitted or 0)


async def _outlet_for(
    session: AsyncSession, user: User, outlet_id: uuid.UUID | None
) -> uuid.UUID | None:
    """Le point de vente d'une caisse qui s'ouvre, ou rien pour la centrale.

    Qui tient la caisse centrale n'a pas de caisse de point de vente : il se
    verserait a lui-meme. Un point de vente inconnu est ignore plutot que
    refuse -- un refus bloquerait la file d'envoi de la tablette, et avec elle
    toutes les ventes de la soiree ; la caisse se fermera alors sur un simple
    comptage, comme avant.
    """
    if outlet_id is None or CENTRAL in permission_codes(user):
        return None
    outlet = await session.get(Outlet, outlet_id)
    if outlet is None or outlet.hotel_id != user.hotel_id or outlet.deleted_at is not None:
        return None
    return outlet.id


@router.get("", response_model=list[CashSessionOut])
async def list_cash_sessions(
    since: dt.date = Query(description="Premier jour inclus (ouverture de la caisse)"),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("cash.session")),
) -> list[CashSession]:
    """Les caisses depuis un jour, pour le rapport du soir.

    La caisse centrale voit celles de tout l'hotel ; un autre agent ne voit
    que les siennes. Une caisse encore ouverte, ou un versement que la
    reception n'a pas encore confirme, descend quelle que soit son anciennete :
    c'est de l'argent en attente, pas de l'historique.
    """
    debut = dt.datetime.combine(since, dt.time.min, tzinfo=dt.timezone.utc)
    stmt = select(CashSession).where(
        CashSession.hotel_id == user.hotel_id,
        CashSession.deleted_at.is_(None),
        or_(
            CashSession.opened_at >= debut,
            CashSession.status == CashSessionStatus.OPEN,
            and_(CashSession.outlet_id.is_not(None), CashSession.received_at.is_(None)),
        ),
    )
    if CENTRAL not in permission_codes(user):
        stmt = stmt.where(CashSession.user_id == user.id)
    result = await session.execute(
        stmt.order_by(CashSession.opened_at.asc().nullsfirst(), CashSession.id)
    )
    return list(result.scalars().all())


@router.post(
    "",
    response_model=CashSessionOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Session deja ouverte pour cet agent : celle-la"}},
)
async def open_cash_session(
    payload: CashSessionOpenIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("cash.session")),
) -> CashSession:
    # Un agent n'a qu'une session ouverte : c'est la cle naturelle, et elle
    # suffit a rendre cette route rejouable. Une tablette qui perd la reponse
    # renvoie la demande ; un 409 bloquerait sa file d'envoi et tout ce qui
    # attend derriere -- y compris les encaissements de la journee.
    #
    # Rendre la session existante est aussi la bonne reponse a une vraie
    # double ouverture : c'est bien celle-la que l'agent doit utiliser. Le
    # fond de caisse renvoye est celui de l'ouverture initiale, pas celui de
    # la demande -- le premier comptage fait foi.
    #
    # Le renvoi d'une ouverture dont la caisse a deja ete fermee depuis porte
    # le meme `id` : on rend cette caisse-la, sans en ouvrir une seconde.
    if payload.id is not None:
        connue = await session.get(CashSession, payload.id)
        if connue is not None:
            if connue.hotel_id != user.hotel_id or connue.user_id != user.id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Session de caisse introuvable.")
            response.status_code = status.HTTP_200_OK
            return connue
    deja = await open_session_id(session, user)
    if deja is not None:
        response.status_code = status.HTTP_200_OK
        return await session.get(CashSession, deja)
    if payload.device_id is not None:
        device = await session.get(Device, payload.device_id)
        if device is None or device.hotel_id != user.hotel_id or device.deleted_at is not None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Appareil inconnu.")

    cash_session = CashSession(
        hotel_id=user.hotel_id,
        user_id=user.id,
        device_id=payload.device_id,
        outlet_id=await _outlet_for(session, user, payload.outlet_id),
        status=CashSessionStatus.OPEN,
        opened_at=dt.datetime.now(dt.timezone.utc),
        opening_float=payload.opening_float,
        expected_amount=payload.opening_float,
        notes=payload.notes,
    )
    if payload.id is not None:
        cash_session.id = payload.id
    session.add(cash_session)
    try:
        await session.commit()
    except IntegrityError as exc:
        # Deux ouvertures simultanees : l'index unique partiel a tranche.
        # Deux ouvertures simultanees : l'index unique a tranche, on rend
        # celle qui a gagne plutot qu'une erreur que l'appelant ne saurait
        # pas traiter autrement qu'en la redemandant.
        await session.rollback()
        gagnante = await open_session_id(session, user)
        if gagnante is None:
            raise HTTPException(
                status.HTTP_409_CONFLICT, "Une session de caisse est deja ouverte."
            ) from exc
        response.status_code = status.HTTP_200_OK
        return await session.get(CashSession, gagnante)
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
    # Deja fermee : c'est un renvoi de la tablette, pas un conflit. Un 409
    # bloquerait sa file d'envoi sur une fermeture pourtant passee -- et le
    # comptage, l'attendu et l'ecart sont deja figes, donc il n'y a rien a
    # refaire. Refermer ne doit surtout pas recalculer : l'ecart constate au
    # moment du comptage est celui qui compte.
    if cash_session.status != CashSessionStatus.OPEN:
        return cash_session

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


@router.post("/{session_id}/receive", response_model=CashSessionOut)
async def receive_remittance(
    session_id: uuid.UUID,
    payload: CashSessionReceiveIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission(CENTRAL)),
) -> CashSession:
    """La reception confirme ce qu'elle recoit d'un point de vente.

    L'agent du point de vente a declare un montant en fermant sa caisse ;
    la reception saisit ce qu'elle a reellement en main. Les deux chiffres
    restent, avec l'attendu : c'est leur comparaison qui dit ou l'argent
    s'est perdu -- au comptoir, ou entre le comptoir et la reception.
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
    if cash_session is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Session de caisse introuvable.")
    # Deja recu : un renvoi de la tablette. Le premier montant confirme fait
    # foi, et le compter une seconde fois gonflerait la caisse centrale.
    if cash_session.received_at is not None:
        return cash_session
    if cash_session.outlet_id is None:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Cette caisse n'est pas celle d'un point de vente."
        )
    if cash_session.status == CashSessionStatus.OPEN:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Ce point de vente n'a pas encore declare son versement."
        )

    # Le versement entre dans la caisse ouverte de celui qui le recoit, comme
    # un encaissement ; verrouillee pour ne pas croiser sa fermeture.
    cash_session.received_session_id = await open_session_id(session, user, for_update=True)
    cash_session.received_amount = payload.received_amount
    cash_session.received_by = user.id
    cash_session.received_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()
    await session.refresh(cash_session)
    return cash_session
