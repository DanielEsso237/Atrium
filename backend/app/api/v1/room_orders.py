"""La commande en chambre : la reception commande, le point de vente livre (F2.6).

Le client appelle la reception depuis sa chambre. Elle commande pour lui a
un point de vente -- le restaurant, le bar --, qui voit la commande arriver
sur sa tablette, la prend en charge, la prepare et la monte. A la livraison,
chaque ligne passe sur l'ardoise du sejour, au nom du point de vente : son
chiffre, son stock, comme une consommation portee a la chambre au comptoir.

    SENT (commandee) --accept--> IN_PREP (prise en charge) --deliver--> SERVED
       \\_____________________________________________________cancel--> CANCELLED

Les refus, tous avant la premiere ecriture, et que la tablette fait avant
d'enfiler :

- a la commande : un point de vente ferme (aucun tiroir ouvert), qui ne
  porte pas sur la chambre, un article qui n'est pas sur sa carte ou plus
  disponible, un sejour sans ardoise ouverte, le plafond du client ;
- a la livraison : le tiroir de l'agent qui livre n'est pas ouvert -- rien ne
  se sert sans lui (decision du 11 octobre).

Le plafond se controle a la commande, pas a la livraison : c'est la que
quelqu'un peut encore dire non. Il compte les commandes deja en route vers
la meme ardoise.

Chaque route est rejouable : la tablette commande et livre hors ligne, et sa
file d'envoi peut renvoyer un geste deja enregistre.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import permission_codes, require_any_permission, require_permission
from app.api.v1.billing import _caisse_ouverte, _check_credit_limit
from app.core.ids import uuid7
from app.db.session import get_session
from app.models import (
    CashSession,
    FolioItem,
    MenuCategory,
    MenuItem,
    Order,
    OrderItem,
    Payment,
    User,
)
from app.models.enums import (
    CashSessionStatus,
    ChargeCategory,
    FolioStatus,
    OrderStatus,
    OrderType,
)
from app.models.reservations import ReservationRoom
from app.models.restaurant import Outlet
from app.schemas.room_orders import (
    RoomOrderCancelIn,
    RoomOrderDeliverIn,
    RoomOrderIn,
    RoomOrderOut,
)
from app.services import folios as folio_service
from app.services.business_day import current_business_date
from app.services.folios import recompute_totals
from app.services.numbering import Scope, next_number
from app.services.outlets import allowed_outlet_ids, ensure_outlet_allowed
from app.services.room_orders import EN_COURS, pending_total
from app.services.stock_levels import deduct_for_sale

router = APIRouter(prefix="/room-orders", tags=["commande en chambre"])

COMMANDER = "room_order.create"


async def _commande(session: AsyncSession, order_id: uuid.UUID, user: User) -> Order:
    """La commande en chambre de cet hotel, verrouillee, ou 404."""
    order = await session.get(Order, order_id, with_for_update=True)
    if (
        order is None
        or order.hotel_id != user.hotel_id
        or order.deleted_at is not None
        or order.type != OrderType.ROOM_SERVICE
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Commande en chambre introuvable.")
    return order


async def _rendre(session: AsyncSession, order: Order) -> Order:
    await session.refresh(order)
    await session.refresh(order, attribute_names=["items"])
    return order


async def _point_de_vente_ouvert(session: AsyncSession, outlet: Outlet) -> None:
    """Un point de vente est ouvert tant qu'un de ses tiroirs l'est.

    Celui de n'importe quel agent : la reception ne tient pas la caisse du
    bar, elle verifie seulement que quelqu'un est la pour servir.
    """
    ouvert = await session.scalar(
        select(CashSession.id)
        .where(
            CashSession.hotel_id == outlet.hotel_id,
            CashSession.outlet_id == outlet.id,
            CashSession.status == CashSessionStatus.OPEN,
            CashSession.deleted_at.is_(None),
        )
        .limit(1)
    )
    if ouvert is None:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"{outlet.label} est ferme (aucune caisse ouverte) : il ne peut pas livrer.",
        )


@router.get("", response_model=list[RoomOrderOut])
async def list_room_orders(
    since: dt.date | None = Query(
        None,
        description=(
            "Premiere journee hoteliere incluse ; les commandes en cours sont "
            "rendues quel que soit leur age. Sans elle : les commandes en cours."
        ),
    ),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.read")),
) -> list[Order]:
    """La descente : les commandes en chambre adressees aux points de vente de l'agent.

    Un agent rattache voit celles de ses points de vente ; la reception, qui
    n'est rattachee a aucun, les voit toutes.
    """
    stmt = select(Order).where(
        Order.hotel_id == user.hotel_id,
        Order.type == OrderType.ROOM_SERVICE,
        Order.deleted_at.is_(None),
    )
    allowed = await allowed_outlet_ids(session, user)
    if allowed is not None:
        stmt = stmt.where(Order.outlet_id.in_(allowed))
    if since is None:
        stmt = stmt.where(Order.status.in_(EN_COURS))
    else:
        stmt = stmt.where(or_(Order.status.in_(EN_COURS), Order.business_date >= since))
    result = await session.scalars(stmt.order_by(Order.opened_at.asc().nullsfirst(), Order.id))
    return list(result.all())


@router.post(
    "",
    response_model=RoomOrderOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Commande deja enregistree (meme id) : celle-la"}},
)
async def create_room_order(
    payload: RoomOrderIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission(COMMANDER)),
) -> Order:
    """La reception commande pour une chambre ; le point de vente la voit arriver."""
    existante = await session.get(Order, payload.id)
    if existante is not None:
        if existante.hotel_id != user.hotel_id or existante.type != OrderType.ROOM_SERVICE:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifiant inconnu.")
        response.status_code = status.HTTP_200_OK
        return await _rendre(session, existante)

    outlet = await session.get(Outlet, payload.outlet_id)
    if (
        outlet is None
        or outlet.hotel_id != user.hotel_id
        or outlet.deleted_at is not None
        or not outlet.is_active
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Point de vente introuvable.")
    if not outlet.allows_room_charge:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"{outlet.label} ne porte pas sur la chambre."
        )
    await _point_de_vente_ouvert(session, outlet)

    folio = await folio_service.get_folio(
        session, payload.folio_id, user.hotel_id, for_update=True
    )
    if folio.status != FolioStatus.OPEN or folio.reservation_room_id is None:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Ce sejour n'a pas d'ardoise ouverte : le client est parti."
        )
    sejour = await session.get(ReservationRoom, folio.reservation_room_id)

    # La carte du point de vente : ses categories, et celles de tout l'hotel.
    menu_ids = {line.menu_item_id for line in payload.items}
    articles = {
        m.id: m
        for m in await session.scalars(
            select(MenuItem)
            .join(MenuCategory, MenuCategory.id == MenuItem.menu_category_id)
            .where(
                MenuItem.id.in_(menu_ids),
                MenuItem.hotel_id == user.hotel_id,
                MenuItem.deleted_at.is_(None),
                MenuItem.is_active.is_(True),
                or_(MenuCategory.outlet_id.is_(None), MenuCategory.outlet_id == outlet.id),
            )
        )
    }
    if menu_ids - articles.keys():
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"Article absent de la carte de {outlet.label}.",
        )
    indisponibles = sorted(m.label for m in articles.values() if not m.is_available)
    if indisponibles:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Plus disponible : {', '.join(indisponibles)}."
        )
    ids_lignes = [line.id for line in payload.items]
    if len(set(ids_lignes)) != len(ids_lignes) or await session.scalar(
        select(OrderItem.id).where(OrderItem.id.in_(ids_lignes)).limit(1)
    ):
        raise HTTPException(status.HTTP_409_CONFLICT, "Identifiant de ligne deja utilise.")

    # Les prix de la carte sont TTC, comme sur l'ardoise : la taxe est la part
    # du montant qui lui revient, pas un supplement.
    total = sum(articles[line.menu_item_id].price * line.quantity for line in payload.items)
    override_by = await _check_credit_limit(
        session,
        folio,
        total + await pending_total(session, folio.id),
        payload.override_by,
        user,
    )

    now = dt.datetime.now(dt.timezone.utc)
    order = Order(
        id=payload.id,
        hotel_id=user.hotel_id,
        number=await next_number(session, user.hotel_id, Scope.ORDER),
        outlet_id=outlet.id,
        type=OrderType.ROOM_SERVICE,
        status=OrderStatus.SENT,
        room_id=sejour.room_id if sejour is not None else None,
        folio_id=folio.id,
        guest_id=folio.guest_id,
        business_date=await current_business_date(session, user.hotel_id),
        opened_at=now,
        sent_at=now,
        ordered_by=user.id,
        override_by=override_by,
        notes=payload.notes,
    )
    session.add(order)
    await session.flush()

    tax_total = 0
    for rang, line in enumerate(payload.items):
        article = articles[line.menu_item_id]
        amount = article.price * line.quantity
        tax_total += amount * article.tax_rate // 100
        session.add(
            OrderItem(
                id=line.id,
                order_id=order.id,
                menu_item_id=article.id,
                prep_station_id=article.prep_station_id,
                label_snapshot=article.label,
                quantity=line.quantity,
                unit_price=article.price,
                tax_rate=article.tax_rate,
                amount=amount,
                status=OrderStatus.SENT,
                notes=line.notes,
                sent_at=now,
                sort_order=rang,
            )
        )
    order.subtotal = total
    order.tax_total = tax_total
    order.total = total

    await session.commit()
    return await _rendre(session, order)


@router.post("/{order_id}/accept", response_model=RoomOrderOut)
async def accept_room_order(
    order_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.manage")),
) -> Order:
    """Le point de vente prend la commande en charge : elle est en preparation."""
    order = await _commande(session, order_id, user)
    await ensure_outlet_allowed(session, user, order.outlet_id)
    if order.status in (OrderStatus.IN_PREP, OrderStatus.SERVED):
        return await _rendre(session, order)  # rejeu, ou deja livree
    if order.status != OrderStatus.SENT:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cette commande a ete annulee.")
    order.status = OrderStatus.IN_PREP
    order.taken_by = user.id
    order.taken_at = dt.datetime.now(dt.timezone.utc)
    for item in order.items:
        if item.status == OrderStatus.SENT:
            item.status = OrderStatus.IN_PREP
    await session.commit()
    return await _rendre(session, order)


@router.post("/{order_id}/deliver", response_model=RoomOrderOut)
async def deliver_room_order(
    order_id: uuid.UUID,
    payload: RoomOrderDeliverIn | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.manage")),
) -> Order:
    """Le plateau est monte : chaque ligne passe sur l'ardoise du sejour.

    La ligne d'ardoise prend l'id de la ligne de commande : la tablette qui
    livre hors ligne ecrit la meme, et rien ne se double au renvoi. Elle porte
    le point de vente (`source_table = 'outlets'`) : son chiffre, son stock.

    Avec `payment`, le client paie a la livraison : le total de la commande,
    dans le tiroir de celui qui livre. Les lignes passent quand meme sur
    l'ardoise -- la facture du sejour les montre --, et le paiement les
    solde : le client ne doit rien de plus.
    """
    order = await _commande(session, order_id, user)
    await ensure_outlet_allowed(session, user, order.outlet_id)
    if order.status == OrderStatus.SERVED:
        return await _rendre(session, order)  # rejeu : deja sur l'ardoise
    if order.status not in EN_COURS:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cette commande a ete annulee.")
    paiement = payload.payment if payload is not None else None
    a_payer = sum(item.amount for item in order.items if not item.is_void)
    if paiement is not None and paiement.amount != a_payer:
        # La monnaie rendue est de la manipulation d'especes, pas une ligne
        # d'ardoise : le paiement couvre la commande, ni plus ni moins.
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Le paiement ({paiement.amount}) doit couvrir la commande ({a_payer}).",
        )
    if paiement is not None and paiement.id is not None:
        deja = await session.get(Payment, paiement.id)
        if deja is not None:
            raise HTTPException(status.HTTP_409_CONFLICT, "Identifiant de paiement deja utilise.")
    caisse = await _caisse_ouverte(
        session,
        user,
        order.outlet_id,
        message="Ouvrez la caisse du point de vente avant de livrer : il est ferme.",
    )
    folio = await folio_service.get_folio(session, order.folio_id, user.hotel_id, for_update=True)
    if folio.status != FolioStatus.OPEN:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "L'ardoise du sejour est close : le client est parti."
        )

    now = dt.datetime.now(dt.timezone.utc)
    for item in order.items:
        if item.is_void:
            continue
        session.add(
            FolioItem(
                id=item.id,
                folio_id=folio.id,
                category=ChargeCategory.FNB,
                label=item.label_snapshot,
                quantity=item.quantity,
                unit_price=item.unit_price,
                amount=item.amount,
                tax_amount=item.amount * item.tax_rate // 100,
                tax_rate=item.tax_rate,
                # La journee de la commande, pas celle de la livraison : un
                # plateau commande a 23 h et monte a 0 h 30 reste sur la meme
                # journee, comme l'addition papier.
                business_date=order.business_date,
                source_table="outlets",
                source_id=order.outlet_id,
                posted_by=user.id,
                posted_at=now,
                override_by=order.override_by,
            )
        )
        item.status = OrderStatus.SERVED
    if paiement is not None:
        # La recette du bar tombe dans le tiroir du bar, sur l'ardoise du
        # sejour : la facture montre la consommation et son paiement.
        session.add(
            Payment(
                id=paiement.id or uuid7(),
                hotel_id=user.hotel_id,
                folio_id=folio.id,
                cash_session_id=caisse,
                method=paiement.method,
                amount=paiement.amount,
                reference=paiement.reference,
                notes=paiement.notes,
                received_by=user.id,
                received_at=now,
                business_date=await current_business_date(session, user.hotel_id),
            )
        )
    await session.flush()
    for item in order.items:
        if not item.is_void:
            await deduct_for_sale(
                session,
                hotel_id=user.hotel_id,
                outlet_id=order.outlet_id,
                menu_item_id=item.menu_item_id,
                quantity=item.quantity,
                folio_item_id=item.id,
                by=user.id,
            )
    await recompute_totals(session, folio)

    order.status = OrderStatus.SERVED
    order.served_at = now
    order.delivered_by = user.id
    if order.taken_by is None:
        # Livree sans prise en charge prealable : celui qui livre l'a prise.
        order.taken_by = user.id
        order.taken_at = now
    await session.commit()
    return await _rendre(session, order)


@router.post("/{order_id}/cancel", response_model=RoomOrderOut)
async def cancel_room_order(
    order_id: uuid.UUID,
    payload: RoomOrderCancelIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_any_permission(COMMANDER, "order.manage")),
) -> Order:
    """Le client se ravise, ou le point de vente ne peut pas servir : avec un motif.

    La reception annule toute commande ; un point de vente, celles qui lui
    sont adressees. Une commande livree ne s'annule plus : elle est sur
    l'ardoise, et c'est la que la ligne se corrige.
    """
    order = await _commande(session, order_id, user)
    if COMMANDER not in permission_codes(user):
        await ensure_outlet_allowed(session, user, order.outlet_id)
    if order.status == OrderStatus.CANCELLED:
        return await _rendre(session, order)  # rejeu
    if order.status == OrderStatus.SERVED:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Cette commande est deja livree : elle est sur l'ardoise."
        )
    order.status = OrderStatus.CANCELLED
    order.cancelled_at = dt.datetime.now(dt.timezone.utc)
    order.cancelled_by = user.id
    order.cancel_reason = payload.reason
    for item in order.items:
        item.status = OrderStatus.CANCELLED
    await session.commit()
    return await _rendre(session, order)
