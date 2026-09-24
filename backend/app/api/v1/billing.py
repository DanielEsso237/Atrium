"""Routes facturation : folios, charges, paiements, factures (F1.4-F1.5)."""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import permission_codes, require_permission
from app.core.ids import uuid7
from app.db.session import get_session
from app.models import (
    CashSession,
    Folio,
    FolioItem,
    Invoice,
    InvoiceLine,
    Payment,
    StayNight,
    User,
)
from app.models.enums import CashSessionStatus, ChargeCategory, FolioStatus, InvoiceStatus
from app.schemas.billing import (
    FolioItemIn,
    FolioItemOut,
    FolioOut,
    InvoiceOut,
    PaymentIn,
)
from app.services.business_day import current_business_date
from app.services import folios as folio_service
from app.services.folios import recompute_totals
from app.services.numbering import Scope, next_number
from app.services.printing import enqueue_print_job

router = APIRouter(tags=["facturation"])


async def _get_folio(
    session: AsyncSession, folio_id: uuid.UUID, user: User, *, for_update: bool = False
) -> Folio:
    return await folio_service.get_folio(
        session, folio_id, user.hotel_id, for_update=for_update
    )


@router.get("/folios", response_model=list[FolioOut])
async def list_folios(
    status_filter: FolioStatus | None = Query(None, alias="status"),
    guest_id: uuid.UUID | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.read")),
) -> list[Folio]:
    stmt = select(Folio).where(Folio.hotel_id == user.hotel_id, Folio.deleted_at.is_(None))
    if status_filter:
        stmt = stmt.where(Folio.status == status_filter)
    if guest_id:
        stmt = stmt.where(Folio.guest_id == guest_id)
    stmt = stmt.order_by(Folio.opened_at.desc().nullslast())
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.get("/folios/{folio_id}", response_model=FolioOut)
async def get_folio(
    folio_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.read")),
) -> Folio:
    folio = await _get_folio(session, folio_id, user)
    await session.refresh(folio, attribute_names=["items"])
    return folio


@router.post(
    "/folios/{folio_id}/items",
    response_model=FolioItemOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Charge deja enregistree (meme id) : etat actuel"}},
)
async def add_folio_item(
    folio_id: uuid.UUID,
    payload: FolioItemIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.write")),
) -> FolioItem:
    """Charge manuelle (minibar, blanchisserie, remise...).

    Une remise (`category=DISCOUNT`) exige en plus `folio.discount` -- c'est
    exactement l'exemple cite par docs/01-modele-de-donnees.md pour justifier
    des permissions granulaires plutot qu'un seul controle global sur le folio.
    """
    folio = await _get_folio(session, folio_id, user, for_update=True)
    # Rejeu avant tout autre controle : une charge renvoyee apres la cloture
    # du folio a bel et bien ete portee, elle ne doit pas recevoir un 409.
    if payload.id is not None:
        existing = await session.get(FolioItem, payload.id)
        if existing is not None:
            if existing.folio_id != folio.id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Charge introuvable.")
            response.status_code = status.HTTP_200_OK
            return existing
    if folio.status != FolioStatus.OPEN:
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce folio n'est plus ouvert.")
    if payload.category == ChargeCategory.DISCOUNT and "folio.discount" not in permission_codes(
        user
    ):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Permission manquante : folio.discount")

    amount = payload.unit_price * payload.quantity
    if payload.category == ChargeCategory.DISCOUNT and amount > 0:
        # Le personnel saisit toujours un montant de remise positif ("500 F
        # de geste commercial") ; c'est ici, pas cote client, que ca devient
        # une ligne negative -- sinon une remise augmente le solde au lieu de
        # le reduire (bug reel trouve en testant ce fichier).
        amount = -amount
    tax_amount = amount * payload.tax_rate // 100
    business_date = await current_business_date(session, user.hotel_id)
    item = FolioItem(
        id=payload.id or uuid7(),
        folio_id=folio.id,
        category=payload.category,
        label=payload.label,
        quantity=payload.quantity,
        unit_price=payload.unit_price,
        amount=amount,
        tax_amount=tax_amount,
        tax_rate=payload.tax_rate,
        business_date=business_date,
        posted_by=user.id,
        posted_at=dt.datetime.now(dt.timezone.utc),
    )
    session.add(item)
    await session.flush()
    await recompute_totals(session, folio)
    await session.commit()
    await session.refresh(item)
    return item


@router.post("/folios/{folio_id}/post-stay-nights", response_model=FolioOut)
async def post_stay_nights(
    folio_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.write")),
) -> Folio:
    """Porte au folio toutes les nuits encore non postees du sejour associe

    (`StayNight.is_posted`) -- version simplifiee, folio par folio, de la
    cloture journaliere du paragraphe 5.1, qui operera plus tard sur tout
    l'hotel d'un coup.
    """
    folio = await _get_folio(session, folio_id, user, for_update=True)
    if folio.reservation_room_id is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "Ce folio n'est pas rattache a un sejour."
        )

    result = await session.execute(
        select(StayNight).where(
            StayNight.reservation_room_id == folio.reservation_room_id,
            StayNight.is_posted.is_(False),
            StayNight.deleted_at.is_(None),
        )
    )
    nights = list(result.scalars().all())
    now = dt.datetime.now(dt.timezone.utc)
    for night in nights:
        session.add(
            FolioItem(
                folio_id=folio.id,
                category=ChargeCategory.ROOM,
                label=f"Nuitee du {night.business_date}",
                quantity=1,
                unit_price=night.rate,
                amount=night.rate,
                tax_amount=0,
                tax_rate=0,
                business_date=night.business_date,
                source_table="stay_nights",
                source_id=night.id,
                posted_by=user.id,
                posted_at=now,
            )
        )
        night.is_posted = True
        night.posted_at = now

    await recompute_totals(session, folio)
    await session.commit()
    await session.refresh(folio, attribute_names=["items"])
    return folio


@router.post(
    "/folios/{folio_id}/payments",
    response_model=FolioOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Paiement deja enregistre (meme id) : etat du folio"}},
)
async def record_payment(
    folio_id: uuid.UUID,
    payload: PaymentIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.write")),
) -> Folio:
    """Encaissement. Un paiement rejoue (meme id) n'est jamais compte deux

    fois : 200 avec l'etat actuel du folio, sans rien reecrire.
    """
    folio = await _get_folio(session, folio_id, user, for_update=True)
    if payload.id is not None:
        existing = await session.get(Payment, payload.id)
        if existing is not None:
            if existing.hotel_id != user.hotel_id or existing.folio_id != folio.id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Paiement introuvable.")
            response.status_code = status.HTTP_200_OK
            await session.refresh(folio, attribute_names=["items"])
            return folio
    if folio.status != FolioStatus.OPEN:
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce folio n'est plus ouvert.")

    # Le solde est recalcule avant d'etre oppose au montant : il est maintenu a
    # chaque ecriture, mais l'opposer a de l'argent merite de le relire plutot
    # que de faire confiance a la colonne.
    #
    # Ce controle arrive **apres** la reprise d'un paiement deja enregistre,
    # plus haut. L'ordre n'est pas negociable : un renvoi de tablette porte sur
    # un paiement qui a justement solde le folio, et le refuser ici bloquerait
    # la file d'envoi et toutes les ecritures derriere elle.
    await recompute_totals(session, folio)
    if folio.balance <= 0:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "Ce folio est deja solde : il n'y a rien a encaisser.",
        )
    if payload.amount > folio.balance:
        # Un client qui tend 60 000 pour une note de 50 000 fait enregistrer
        # 50 000 : les 10 000 rendus sont de la manipulation d'especes, pas une
        # ligne de folio. Sans ce refus le solde passe en negatif, et l'ecart
        # n'apparait qu'a la fermeture de caisse, sans qu'on sache de quel
        # client il vient.
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Il ne reste que {folio.balance} a encaisser sur ce folio.",
        )

    # Rattachement a la session de caisse ouverte du caissier : c'est ce qui
    # permet de calculer l'attendu et l'ecart a la fermeture. La ligne de
    # session est verrouillee pour ne pas croiser une fermeture en cours.
    cash_session_id = await session.scalar(
        select(CashSession.id)
        .where(
            CashSession.user_id == user.id,
            CashSession.status == CashSessionStatus.OPEN,
            CashSession.deleted_at.is_(None),
        )
        .with_for_update()
    )

    business_date = await current_business_date(session, user.hotel_id)
    payment = Payment(
        id=payload.id or uuid7(),
        hotel_id=user.hotel_id,
        folio_id=folio.id,
        cash_session_id=cash_session_id,
        method=payload.method,
        amount=payload.amount,
        reference=payload.reference,
        notes=payload.notes,
        received_by=user.id,
        received_at=dt.datetime.now(dt.timezone.utc),
        business_date=business_date,
    )
    session.add(payment)
    await session.flush()
    await recompute_totals(session, folio)
    await session.commit()
    await session.refresh(folio, attribute_names=["items"])
    return folio


@router.post("/folios/{folio_id}/close", response_model=FolioOut)
async def close_folio(
    folio_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.write")),
) -> Folio:
    folio = await _get_folio(session, folio_id, user, for_update=True)
    if folio.status != FolioStatus.OPEN:
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce folio n'est pas ouvert.")
    if folio.balance != 0:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Le solde n'est pas nul (balance={folio.balance}) : impossible de clore.",
        )
    folio.status = FolioStatus.CLOSED
    folio.closed_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()
    await session.refresh(folio, attribute_names=["items"])
    return folio


@router.post(
    "/folios/{folio_id}/invoice", response_model=InvoiceOut, status_code=status.HTTP_201_CREATED
)
async def issue_invoice(
    folio_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("folio.write")),
) -> Invoice:
    """Gel du folio a l'instant present (F1.4).

    Cette route s'execute directement sur le serveur central -- contrairement
    a une facture emise hors ligne depuis une tablette, elle n'a pas besoin de
    numero provisoire : `next_number` attribue tout de suite le numero
    legal definitif (voir le commentaire du modele `Invoice` et
    app/services/numbering.py).
    """
    folio = await _get_folio(session, folio_id, user, for_update=True)

    result = await session.execute(
        select(FolioItem).where(FolioItem.folio_id == folio.id, FolioItem.is_void.is_(False))
    )
    items = list(result.scalars().all())
    if not items:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "Ce folio n'a aucune charge a facturer."
        )

    subtotal = sum(i.amount - i.tax_amount for i in items)
    tax_total = sum(i.tax_amount for i in items)
    total = sum(i.amount for i in items)

    # Numero legal attribue en dernier, une fois tous les controles passes :
    # le verrou de la sequence n'est tenu que jusqu'au commit, juste apres.
    number = await next_number(session, user.hotel_id, Scope.INVOICE)

    invoice = Invoice(
        hotel_id=user.hotel_id,
        number=number,
        is_provisional=False,
        folio_id=folio.id,
        guest_id=folio.guest_id,
        status=InvoiceStatus.ISSUED,
        issued_at=dt.datetime.now(dt.timezone.utc),
        subtotal=subtotal,
        tax_total=tax_total,
        total=total,
        currency="XOF",
    )
    session.add(invoice)
    await session.flush()

    for i, item in enumerate(items):
        session.add(
            InvoiceLine(
                invoice_id=invoice.id,
                folio_item_id=item.id,
                label=item.label,
                quantity=item.quantity,
                unit_price=item.unit_price,
                tax_rate=item.tax_rate,
                tax_amount=item.tax_amount,
                amount=item.amount,
                sort_order=i,
            )
        )

    await enqueue_print_job(
        session,
        user.hotel_id,
        "GUEST_INVOICE",
        payload={
            "invoice_number": number,
            "total": total,
            "currency": invoice.currency,
            "lines": [{"label": i.label, "amount": i.amount} for i in items],
        },
        source_table="invoices",
        source_id=invoice.id,
        requested_by=user.id,
    )

    await session.commit()
    await session.refresh(invoice, attribute_names=["lines"])
    return invoice
