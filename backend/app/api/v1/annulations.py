"""Revenir en arriere : annuler une arrivee, un depart, un encaissement.

Demande du 16 octobre : une erreur de saisie au comptoir doit pouvoir se
defaire, mais pas par celui qui l'a faite. Chaque annulation porte le
responsable qui l'a autorisee (`approved_by`, permission `operations.undo`),
dont le code a ete saisi sur la tablette -- meme quand c'est lui qui est
connecte. Le serveur reverifie ce droit ici, comme pour un depassement de
plafond, et garde la trace du geste dans `audit_logs`.

Rien ne s'efface :

- une **arrivee annulee** rend la ligne a l'etat confirme (une arrivee
  directe, qui n'avait pas de reservation, est annulee), la chambre libre, et
  l'ardoise retiree -- ses lignes annulees, ses arrhes rendues au dossier ;
- un **depart annule** remet le client dans sa chambre et rouvre son ardoise ;
- un **encaissement annule** devient un remboursement du meme montant, dans
  le tiroir de celui qui annule : l'argent sort du tiroir et l'attendu le voit
  sortir.

Chaque route est rejouable : un renvoi de la tablette trouve le travail fait
et rend l'etat actuel.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import permission_codes, require_any_permission, require_permission
from app.api.v1.cash_sessions import open_session_id
from app.db.session import get_session
from app.models import (
    AuditLog,
    CashSession,
    Folio,
    FolioItem,
    Payment,
    Reservation,
    ReservationRoom,
    Room,
    StayNight,
    User,
)
from app.models.enums import (
    ChargeCategory,
    FolioStatus,
    OccupancyStatus,
    ReservationStatus,
)
from app.schemas.annulations import PaymentReverseIn, UndoIn
from app.schemas.billing import FolioOut
from app.schemas.reservations import ReservationOut
from app.services.business_day import current_business_date
from app.services.folios import get_folio, recompute_totals
from app.services.room_orders import ensure_none_pending

router = APIRouter(tags=["annulations"])

UNDO = "operations.undo"


async def check_approver(session: AsyncSession, approved_by: uuid.UUID, user: User) -> User:
    """Le responsable designe existe, dans cet hotel, actif, et a le droit."""
    approver = await session.get(User, approved_by, populate_existing=True)
    if (
        approver is None
        or approver.hotel_id != user.hotel_id
        or approver.deleted_at is not None
        or not approver.is_active
        or UNDO not in permission_codes(approver)
    ):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "Cette personne ne peut pas autoriser une annulation "
            f"(permission {UNDO}).",
        )
    return approver


def _trace(
    session: AsyncSession,
    user: User,
    table: str,
    entity_id: uuid.UUID,
    action: str,
    payload: UndoIn,
    **details: object,
) -> None:
    session.add(
        AuditLog(
            user_id=user.id,
            entity_table=table,
            entity_id=entity_id,
            action=action,
            after={
                "approved_by": str(payload.approved_by),
                "reason": payload.reason,
                **{k: str(v) if isinstance(v, uuid.UUID) else v for k, v in details.items()},
            },
            occurred_at=dt.datetime.now(dt.timezone.utc),
        )
    )


async def _line(
    session: AsyncSession, reservation_id: uuid.UUID, line_id: uuid.UUID, user: User
) -> tuple[Reservation, ReservationRoom]:
    reservation = await session.get(Reservation, reservation_id)
    if (
        reservation is None
        or reservation.hotel_id != user.hotel_id
        or reservation.deleted_at is not None
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Reservation introuvable.")
    line = await session.scalar(
        select(ReservationRoom)
        .where(
            ReservationRoom.id == line_id,
            ReservationRoom.reservation_id == reservation.id,
            ReservationRoom.deleted_at.is_(None),
        )
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if line is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ligne de reservation introuvable.")
    return reservation, line


def _reservation_status(reservation: Reservation) -> ReservationStatus:
    """Le statut du dossier se deduit de ses lignes, la plus avancee d'abord."""
    lines = [r for r in reservation.rooms if r.deleted_at is None]
    statuses = {r.status for r in lines}
    for s in (
        ReservationStatus.CHECKED_IN,
        ReservationStatus.CONFIRMED,
        ReservationStatus.PENDING,
        ReservationStatus.CHECKED_OUT,
        ReservationStatus.NO_SHOW,
    ):
        if s in statuses:
            return s
    return ReservationStatus.CANCELLED


@router.post(
    "/reservations/{reservation_id}/rooms/{room_line_id}/undo-check-in",
    response_model=ReservationOut,
)
async def undo_check_in(
    reservation_id: uuid.UUID,
    room_line_id: uuid.UUID,
    payload: UndoIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.manage")),
) -> Reservation:
    """Annule une arrivee enregistree par erreur.

    Refuse tant que l'ardoise porte autre chose que le sejour : un
    encaissement (a annuler d'abord, il a fait entrer de l'argent dans un
    tiroir) ou une consommation (qui a fait sortir du stock). Les arrhes,
    elles, retournent sur le dossier : elles avaient ete versees avant
    l'arrivee et le restent.
    """
    reservation, line = await _line(session, reservation_id, room_line_id, user)
    if line.status != ReservationStatus.CHECKED_IN:
        if line.checked_in_at is None and line.status in (
            ReservationStatus.PENDING,
            ReservationStatus.CONFIRMED,
            ReservationStatus.CANCELLED,
        ):
            await session.refresh(reservation, attribute_names=["rooms"])
            return reservation  # rejeu : l'arrivee est deja annulee
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Impossible d'annuler l'arrivee (statut actuel : {line.status}).",
        )
    await check_approver(session, payload.approved_by, user)

    folio = await session.scalar(
        select(Folio)
        .where(Folio.reservation_room_id == line.id, Folio.deleted_at.is_(None))
        .with_for_update()
    )
    deposit_note = f"Arrhes {reservation.reference}"
    if folio is not None:
        encaisse = await session.scalar(
            select(
                func.coalesce(
                    func.sum(case((Payment.is_refund, -Payment.amount), else_=Payment.amount)),
                    0,
                )
            ).where(
                Payment.folio_id == folio.id,
                Payment.deleted_at.is_(None),
                func.coalesce(Payment.notes, "") != deposit_note,
            )
        )
        if int(encaisse or 0) != 0:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                "Des encaissements sont enregistres sur l'ardoise : "
                "annulez-les d'abord.",
            )
        autres = await session.scalar(
            select(func.count()).where(
                FolioItem.folio_id == folio.id,
                FolioItem.is_void.is_(False),
                FolioItem.deleted_at.is_(None),
                FolioItem.category != ChargeCategory.ROOM,
            )
        )
        if autres:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                "Des consommations sont portees sur l'ardoise : "
                "l'arrivee ne peut plus etre annulee.",
            )
        # Une commande en route serait livree sur une ardoise retiree.
        await ensure_none_pending(session, folio.id, "d'annuler l'arrivee")

    now = dt.datetime.now(dt.timezone.utc)
    if folio is not None:
        items = (
            await session.scalars(
                select(FolioItem).where(
                    FolioItem.folio_id == folio.id,
                    FolioItem.is_void.is_(False),
                    FolioItem.deleted_at.is_(None),
                )
            )
        ).all()
        for item in items:
            item.is_void = True
            item.void_reason = f"Arrivee annulee : {payload.reason}"[:255]
            item.voided_by = payload.approved_by
        # Les arrhes reviennent sur le dossier, dans l'etat ou l'arrivee les
        # avait trouvees : une seconde arrivee les fera basculer a nouveau.
        deposit = await session.scalar(
            select(Payment)
            .where(
                Payment.folio_id == folio.id,
                Payment.notes == deposit_note,
                Payment.is_refund.is_(False),
                Payment.deleted_at.is_(None),
            )
            .with_for_update()
        )
        if deposit is not None and not line.is_walk_in:
            deposit.folio_id = None
            deposit.reservation_id = reservation.id
        await session.flush()
        await recompute_totals(session, folio)
        # Retiree et non close : une nouvelle arrivee ouvrira une ardoise
        # neuve (l'index unique ne compte que les ardoises vivantes).
        folio.deleted_at = now

    nights = (
        await session.scalars(select(StayNight).where(StayNight.reservation_room_id == line.id))
    ).all()
    for night in nights:
        night.is_posted = False
        night.posted_at = None

    line.status = (
        ReservationStatus.CANCELLED if line.is_walk_in else ReservationStatus.CONFIRMED
    )
    line.checked_in_at = None
    line.checked_in_by = None

    if line.room_id is not None:
        room = await session.get(Room, line.room_id, with_for_update=True)
        occupee_ailleurs = await session.scalar(
            select(func.count()).where(
                ReservationRoom.room_id == line.room_id,
                ReservationRoom.id != line.id,
                ReservationRoom.status == ReservationStatus.CHECKED_IN,
                ReservationRoom.deleted_at.is_(None),
            )
        )
        if room is not None and not occupee_ailleurs:
            room.occupancy_status = OccupancyStatus.VACANT

    await session.flush()
    await session.refresh(reservation, attribute_names=["rooms"])
    reservation.status = _reservation_status(reservation)
    _trace(session, user, "reservation_rooms", line.id, "UNDO_CHECK_IN", payload,
           folio_id=folio.id if folio else None)
    await session.commit()
    await session.refresh(reservation, attribute_names=["rooms"])
    return reservation


@router.post(
    "/reservations/{reservation_id}/rooms/{room_line_id}/undo-check-out",
    response_model=ReservationOut,
)
async def undo_check_out(
    reservation_id: uuid.UUID,
    room_line_id: uuid.UUID,
    payload: UndoIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("reservation.manage")),
) -> Reservation:
    """Annule un depart enregistre par erreur : le client reprend sa chambre.

    Refuse si la chambre a deja ete redonnee a quelqu'un d'autre. L'ardoise
    se rouvre si le depart l'avait close ; la chambre garde son etat de
    menage (le client y est reste, elle n'est pas plus propre pour autant).
    """
    reservation, line = await _line(session, reservation_id, room_line_id, user)
    if line.status == ReservationStatus.CHECKED_IN:
        await session.refresh(reservation, attribute_names=["rooms"])
        return reservation  # rejeu : le depart est deja annule
    if line.status != ReservationStatus.CHECKED_OUT:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Impossible d'annuler le depart (statut actuel : {line.status}).",
        )
    await check_approver(session, payload.approved_by, user)

    if line.room_id is not None:
        room = await session.get(Room, line.room_id, with_for_update=True)
        if room is not None and room.occupancy_status == OccupancyStatus.OCCUPIED:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"La chambre {room.number} est deja occupee par un autre sejour.",
            )
        if room is not None:
            room.occupancy_status = OccupancyStatus.OCCUPIED

    line.status = ReservationStatus.CHECKED_IN
    line.checked_out_at = None
    line.checked_out_by = None

    folio = await session.scalar(
        select(Folio)
        .where(Folio.reservation_room_id == line.id, Folio.deleted_at.is_(None))
        .with_for_update()
    )
    if folio is not None and folio.status != FolioStatus.OPEN:
        folio.status = FolioStatus.OPEN
        folio.closed_at = None

    await session.flush()
    await session.refresh(reservation, attribute_names=["rooms"])
    reservation.status = _reservation_status(reservation)
    _trace(session, user, "reservation_rooms", line.id, "UNDO_CHECK_OUT", payload)
    await session.commit()
    await session.refresh(reservation, attribute_names=["rooms"])
    return reservation


@router.post(
    "/payments/{payment_id}/reverse",
    response_model=FolioOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Annulation deja enregistree (meme id)"}},
)
async def reverse_payment(
    payment_id: uuid.UUID,
    payload: PaymentReverseIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_any_permission("folio.write", "cash.session")),
) -> Folio:
    """Annule un encaissement : un remboursement du meme montant.

    L'argent sort du tiroir de celui qui annule, pour le point de vente de
    l'encaissement (la caisse centrale pour la reception) : sans tiroir
    ouvert, pas d'annulation, comme pas d'encaissement. L'ardoise se rouvre
    si le paiement l'avait soldee et close. Les arrhes ne s'annulent pas
    ici : elles suivent le dossier.
    """
    if "cash.session" not in permission_codes(user):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Permission manquante : cash.session")

    existing = await session.get(Payment, payload.id)
    if existing is not None:
        if existing.hotel_id != user.hotel_id or existing.reverses_payment_id != payment_id:
            raise HTTPException(status.HTTP_409_CONFLICT, "Identifiant deja utilise.")
        response.status_code = status.HTTP_200_OK
        folio = await get_folio(session, existing.folio_id, user.hotel_id)
        await session.refresh(folio, attribute_names=["items"])
        return folio

    original = await session.get(Payment, payment_id, with_for_update=True)
    if original is None or original.hotel_id != user.hotel_id or original.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Encaissement introuvable.")
    if original.is_refund:
        raise HTTPException(status.HTTP_409_CONFLICT, "Un remboursement ne s'annule pas.")
    if original.folio_id is None:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Des arrhes ne s'annulent pas ici : elles suivent le dossier."
        )
    deja = await session.scalar(
        select(Payment.id).where(
            Payment.reverses_payment_id == original.id, Payment.deleted_at.is_(None)
        )
    )
    if deja is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cet encaissement est deja annule.")
    await check_approver(session, payload.approved_by, user)

    outlet_id = None
    if original.cash_session_id is not None:
        outlet_id = await session.scalar(
            select(CashSession.outlet_id).where(CashSession.id == original.cash_session_id)
        )
    cash_session_id = await open_session_id(session, user, outlet_id=outlet_id, for_update=True)
    if cash_session_id is None:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "Ouvrez votre caisse avant d'annuler : l'argent rendu sort d'un tiroir.",
        )

    folio = await get_folio(session, original.folio_id, user.hotel_id, for_update=True)
    now = dt.datetime.now(dt.timezone.utc)
    session.add(
        Payment(
            id=payload.id,
            hotel_id=user.hotel_id,
            folio_id=folio.id,
            cash_session_id=cash_session_id,
            method=original.method,
            amount=original.amount,
            reference=original.reference,
            notes=f"Annulation : {payload.reason}"[:255],
            received_by=user.id,
            received_at=now,
            business_date=await current_business_date(session, user.hotel_id),
            is_refund=True,
            reverses_payment_id=original.id,
        )
    )
    await session.flush()
    await recompute_totals(session, folio)
    if folio.status != FolioStatus.OPEN and folio.balance != 0:
        folio.status = FolioStatus.OPEN
        folio.closed_at = None
    _trace(session, user, "payments", original.id, "REVERSE_PAYMENT", payload,
           refund_id=payload.id, amount=original.amount)
    await session.commit()
    await session.refresh(folio, attribute_names=["items"])
    return folio
