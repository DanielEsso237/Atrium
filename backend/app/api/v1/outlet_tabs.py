"""Les ardoises du comptoir : consommer d'abord, payer a la fin.

Au bar, un client prend une biere, puis un jus, et demande sa note en
partant (decision du 12 octobre). L'ardoise du comptoir appartient a son
point de vente et cumule ses consommations (`POST /folios/{id}/items`, avec
`outlet_id`). Elle se termine de trois facons :

- **payee** au comptoir, le total d'un coup, dans le tiroir du point de vente ;
- **portee a la chambre** pour un client loge : toutes ses lignes passent sur
  l'ardoise du sejour, en gardant leur point de vente ;
- **annulee** avec un motif, par un responsable, quand le client est parti
  sans payer. Les lignes restent, annulees : ce qui a ete servi est sorti du
  stock, et la piste d'audit garde qui a annule et pourquoi.

Chaque route est rejouable : la tablette ouvre et complete l'ardoise hors
ligne, et sa file d'envoi peut renvoyer un geste deja enregistre.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

# Les memes garde-fous que le reste de la facturation : le tiroir ouvert du
# point de vente, et le seuil de consommation du client.
from app.api.v1.billing import _caisse_ouverte, _check_credit_limit
from app.api.deps import require_permission
from app.core.ids import uuid7
from app.db.session import get_session
from app.models import Folio, FolioItem, Guest, Payment, User
from app.models.enums import FolioStatus, FolioType
from app.models.restaurant import Outlet
from app.schemas.billing import FolioOut
from app.schemas.outlet_tabs import (
    OutletTabCancelIn,
    OutletTabOpenIn,
    OutletTabSettleIn,
    OutletTabToRoomIn,
)
from app.services import folios as folio_service
from app.services.business_day import current_business_date
from app.services.folios import recompute_totals
from app.services.numbering import Scope, next_number
from app.services.outlets import ensure_outlet_allowed

router = APIRouter(prefix="/outlet-tabs", tags=["points de vente"])


async def _ardoise(session: AsyncSession, tab_id: uuid.UUID, user: User) -> Folio:
    """L'ardoise d'un comptoir de cet hotel, verrouillee, ou 404."""
    folio = await folio_service.get_folio(session, tab_id, user.hotel_id, for_update=True)
    if folio.outlet_id is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ardoise de comptoir introuvable.")
    return folio


async def _rendre(session: AsyncSession, folio: Folio) -> Folio:
    await session.refresh(folio, attribute_names=["items"])
    return folio


@router.post(
    "",
    response_model=FolioOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Ardoise deja ouverte (meme id) : celle-la"}},
)
async def open_tab(
    payload: OutletTabOpenIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.charge")),
) -> Folio:
    """Ouvre l'ardoise d'un client au comptoir : de passage, ou loge."""
    existante = await session.get(Folio, payload.id)
    if existante is not None:
        if existante.hotel_id != user.hotel_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifiant inconnu.")
        response.status_code = status.HTTP_200_OK
        return await _rendre(session, existante)

    outlet = await session.get(Outlet, payload.outlet_id)
    if outlet is None or outlet.hotel_id != user.hotel_id or outlet.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Point de vente introuvable.")
    await ensure_outlet_allowed(session, user, outlet.id)
    # Rien ne se sert sans le tiroir ouvert du point de vente (decision du
    # 11 octobre) : une ardoise ouverte, c'est deja servir.
    await _caisse_ouverte(
        session,
        user,
        outlet.id,
        message="Ouvrez la caisse du point de vente avant de servir : il est ferme.",
    )
    if payload.guest_id is not None:
        client = await session.get(Guest, payload.guest_id)
        if client is None or client.hotel_id != user.hotel_id or client.deleted_at is not None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Client introuvable.")

    folio = Folio(
        id=payload.id,
        hotel_id=user.hotel_id,
        number=await next_number(session, user.hotel_id, Scope.FOLIO),
        type=FolioType.WALK_IN,
        status=FolioStatus.OPEN,
        outlet_id=outlet.id,
        tab_number=payload.tab_number,
        guest_id=payload.guest_id,
        opened_at=dt.datetime.now(dt.timezone.utc),
        notes=f"Ardoise n°{payload.tab_number} - {outlet.label}",
    )
    session.add(folio)
    await session.commit()
    return await _rendre(session, folio)


@router.post(
    "/{tab_id}/settle",
    response_model=FolioOut,
    responses={200: {"description": "Ardoise payee, ou deja payee par ce paiement"}},
)
async def settle_tab(
    tab_id: uuid.UUID,
    payload: OutletTabSettleIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("cash.session")),
) -> Folio:
    """Le client paie sa note : le total, d'un coup, et l'ardoise se clot."""
    folio = await _ardoise(session, tab_id, user)
    if payload.payment.id is not None:
        deja = await session.get(Payment, payload.payment.id)
        if deja is not None:
            if deja.hotel_id != user.hotel_id or deja.folio_id != folio.id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Paiement introuvable.")
            return await _rendre(session, folio)
    if folio.status != FolioStatus.OPEN:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cette ardoise n'est plus ouverte.")

    await recompute_totals(session, folio)
    if folio.balance <= 0:
        raise HTTPException(status.HTTP_409_CONFLICT, "Il n'y a rien a payer sur cette ardoise.")
    if payload.payment.amount != folio.balance:
        # La monnaie rendue est de la manipulation d'especes, pas une ligne
        # d'ardoise : le paiement couvre le total, ni plus ni moins.
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Le paiement ({payload.payment.amount}) doit couvrir le total ({folio.balance}).",
        )
    # La recette du bar tombe dans le tiroir du bar.
    caisse = await _caisse_ouverte(session, user, folio.outlet_id)

    now = dt.datetime.now(dt.timezone.utc)
    session.add(
        Payment(
            id=payload.payment.id or uuid7(),
            hotel_id=user.hotel_id,
            folio_id=folio.id,
            cash_session_id=caisse,
            method=payload.payment.method,
            amount=payload.payment.amount,
            reference=payload.payment.reference,
            notes=payload.payment.notes,
            received_by=user.id,
            received_at=now,
            business_date=await current_business_date(session, user.hotel_id),
        )
    )
    await session.flush()
    await recompute_totals(session, folio)
    folio.status = FolioStatus.CLOSED
    folio.closed_at = now
    await session.commit()
    return await _rendre(session, folio)


@router.post("/{tab_id}/to-room", response_model=FolioOut)
async def tab_to_room(
    tab_id: uuid.UUID,
    payload: OutletTabToRoomIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.charge")),
) -> Folio:
    """Porte toute l'ardoise sur la chambre : le client paiera au depart.

    Les lignes changent d'ardoise sans changer de point de vente : le chiffre
    du bar reste au bar, et le client retrouve sa biere sur sa facture de
    sejour.
    """
    folio = await _ardoise(session, tab_id, user)
    if folio.status != FolioStatus.OPEN:
        # Renvoi d'un report deja fait : l'ardoise est close, il n'y a rien
        # a refaire. Le refuser bloquerait la file d'envoi de la tablette.
        return await _rendre(session, folio)
    await recompute_totals(session, folio)
    if folio.payments_total != 0:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Cette ardoise a deja un paiement : elle se paie au comptoir."
        )
    outlet = await session.get(Outlet, folio.outlet_id)
    if outlet is None or not outlet.allows_room_charge:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Ce point de vente ne porte pas sur la chambre."
        )
    chambre = await folio_service.get_folio(
        session, payload.room_folio_id, user.hotel_id, for_update=True
    )
    if chambre.status != FolioStatus.OPEN or chambre.reservation_room_id is None:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Ce sejour n'a pas d'ardoise ouverte : le client est parti."
        )
    # Le seuil compte deja l'ardoise du bar quand elle est au nom du meme
    # client : la porter a sa chambre ne change pas ce qu'il doit. Pour
    # quelqu'un d'autre, c'est une nouvelle dette, qui se controle.
    if folio.guest_id is None or folio.guest_id != chambre.guest_id:
        await _check_credit_limit(session, chambre, folio.balance, payload.override_by, user)

    await session.execute(
        update(FolioItem)
        .where(FolioItem.folio_id == folio.id, FolioItem.deleted_at.is_(None))
        .values(folio_id=chambre.id)
    )
    # Les lignes ont change d'ardoise en base : les objets en memoire, non.
    # L'hotel est lu avant : expirer l'agent ferait relire `user.hotel_id`
    # hors de l'asynchrone (MissingGreenlet).
    hotel_id = user.hotel_id
    session.expire_all()
    folio = await folio_service.get_folio(session, tab_id, hotel_id)
    chambre = await folio_service.get_folio(session, payload.room_folio_id, hotel_id)
    await recompute_totals(session, chambre)
    await recompute_totals(session, folio)
    folio.status = FolioStatus.CLOSED
    folio.closed_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()
    return await _rendre(session, folio)


@router.post("/{tab_id}/cancel", response_model=FolioOut)
async def cancel_tab(
    tab_id: uuid.UUID,
    payload: OutletTabCancelIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("tab.cancel")),
) -> Folio:
    """Le client est parti sans payer : l'ardoise s'annule, avec un motif."""
    folio = await _ardoise(session, tab_id, user)
    if folio.status != FolioStatus.OPEN:
        return await _rendre(session, folio)
    await recompute_totals(session, folio)
    if folio.payments_total != 0:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Cette ardoise a deja un paiement : elle ne s'annule pas."
        )
    await session.execute(
        update(FolioItem)
        .where(
            FolioItem.folio_id == folio.id,
            FolioItem.deleted_at.is_(None),
            FolioItem.is_void.is_(False),
        )
        .values(is_void=True, void_reason=payload.reason, voided_by=user.id)
    )
    hotel_id = user.hotel_id
    session.expire_all()
    folio = await folio_service.get_folio(session, tab_id, hotel_id)
    await recompute_totals(session, folio)
    folio.status = FolioStatus.CLOSED
    folio.closed_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()
    return await _rendre(session, folio)
