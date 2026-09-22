"""Routes commandes restaurant : prise de commande, envoi, service (F3.1-F3.6)."""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import Folio, FolioItem, MenuItem, Order, OrderItem, ReservationRoom, User
from app.models.enums import ChargeCategory, FolioStatus, OrderStatus, OrderType, ReservationStatus
from app.schemas.orders import OrderIn, OrderOut
from app.services.printing import enqueue_print_job

router = APIRouter(prefix="/orders", tags=["commandes"])


async def _next_order_number(session: AsyncSession, hotel_id: uuid.UUID) -> str:
    count = await session.scalar(
        select(func.count()).select_from(Order).where(Order.hotel_id == hotel_id)
    )
    return f"ORD-{(count or 0) + 1:06d}"


async def _get_order(session: AsyncSession, order_id: uuid.UUID, user: User) -> Order:
    order = await session.get(Order, order_id)
    if order is None or order.hotel_id != user.hotel_id or order.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Commande introuvable.")
    return order


@router.get("", response_model=list[OrderOut])
async def list_orders(
    status_filter: OrderStatus | None = Query(None, alias="status"),
    outlet_id: uuid.UUID | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.read")),
) -> list[Order]:
    stmt = select(Order).where(Order.hotel_id == user.hotel_id, Order.deleted_at.is_(None))
    if status_filter:
        stmt = stmt.where(Order.status == status_filter)
    if outlet_id:
        stmt = stmt.where(Order.outlet_id == outlet_id)
    stmt = stmt.order_by(Order.opened_at.desc().nullslast())
    result = await session.execute(stmt)
    return list(result.scalars().all())


@router.get("/{order_id}", response_model=OrderOut)
async def get_order(
    order_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.read")),
) -> Order:
    return await _get_order(session, order_id, user)


@router.post("", response_model=OrderOut, status_code=status.HTTP_201_CREATED)
async def create_order(
    payload: OrderIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.create")),
) -> Order:
    if payload.type == OrderType.ROOM_SERVICE and payload.room_id is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "room_id est obligatoire pour un room service."
        )

    order = Order(
        hotel_id=user.hotel_id,
        number=await _next_order_number(session, user.hotel_id),
        outlet_id=payload.outlet_id,
        type=payload.type,
        status=OrderStatus.DRAFT,
        restaurant_table_id=payload.restaurant_table_id,
        room_id=payload.room_id,
        guest_id=payload.guest_id,
        covers=payload.covers,
        business_date=dt.date.today(),
        opened_at=dt.datetime.now(dt.timezone.utc),
        notes=payload.notes,
    )
    session.add(order)
    await session.flush()

    subtotal = 0
    tax_total = 0
    for line in payload.items:
        menu_item = await session.get(MenuItem, line.menu_item_id)
        if menu_item is None or menu_item.hotel_id != user.hotel_id:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, "Article de menu invalide."
            )
        if not menu_item.is_available:
            raise HTTPException(
                status.HTTP_409_CONFLICT, f"'{menu_item.label}' n'est plus disponible."
            )
        amount = menu_item.price * line.quantity
        tax_amount = amount * menu_item.tax_rate // 100
        session.add(
            OrderItem(
                order_id=order.id,
                menu_item_id=menu_item.id,
                prep_station_id=menu_item.prep_station_id,
                label_snapshot=menu_item.label,
                quantity=line.quantity,
                unit_price=menu_item.price,
                tax_rate=menu_item.tax_rate,
                amount=amount,
                status=OrderStatus.DRAFT,
                notes=line.notes,
            )
        )
        subtotal += amount
        tax_total += tax_amount

    order.subtotal = subtotal
    order.tax_total = tax_total
    order.total = subtotal + tax_total

    await session.commit()
    await session.refresh(order, attribute_names=["items"])
    return order


@router.post("/{order_id}/send", response_model=OrderOut)
async def send_order(
    order_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.manage")),
) -> Order:
    """Bascule DRAFT -> SENT (F3.2) et met en file un ticket par poste de

    preparation concerne (regle R1), via `app.services.printing`.
    """
    order = await _get_order(session, order_id, user)
    if order.status != OrderStatus.DRAFT:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible d'envoyer (statut actuel : {order.status})."
        )
    now = dt.datetime.now(dt.timezone.utc)
    order.status = OrderStatus.SENT
    order.sent_at = now
    for item in order.items:
        item.status = OrderStatus.SENT
        item.sent_at = now

    # R1 : un ticket par poste de preparation concerne, pas un par article --
    # la cuisine ne veut pas 4 bouts de papier pour 4 plats de la meme table.
    # Un seul code de document (KITCHEN_TICKET) sert tous les postes : c'est
    # `prep_station_id` (deja porte par chaque ligne depuis la creation) qui
    # distingue cuisine et bar via les regles de routage, pas le type de
    # document. Best-effort : sans regle configuree pour un poste, la commande
    # part quand meme, seul le ticket papier manque.
    items_by_station: dict[uuid.UUID, list[OrderItem]] = {}
    for item in order.items:
        if item.prep_station_id is not None:
            items_by_station.setdefault(item.prep_station_id, []).append(item)

    for station_id, items in items_by_station.items():
        await enqueue_print_job(
            session,
            user.hotel_id,
            "KITCHEN_TICKET",
            payload={
                "order_number": order.number,
                "table": str(order.restaurant_table_id) if order.restaurant_table_id else None,
                "room": str(order.room_id) if order.room_id else None,
                "items": [
                    {"label": i.label_snapshot, "quantity": i.quantity, "notes": i.notes}
                    for i in items
                ],
            },
            outlet_id=order.outlet_id,
            prep_station_id=station_id,
            source_table="orders",
            source_id=order.id,
            requested_by=user.id,
        )

    await session.commit()
    await session.refresh(order, attribute_names=["items"])
    return order


@router.post("/{order_id}/serve", response_model=OrderOut)
async def serve_order(
    order_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.manage")),
) -> Order:
    """F3.3/F3.6 -- marque la commande servie et, pour un room service,

    reporte immediatement le montant sur le folio de la chambre : c'est
    exactement le decouplage decrit par le modele `Folio` ("un report en
    chambre est une charge sur le folio de la chambre").
    """
    order = await _get_order(session, order_id, user)
    if order.status not in (OrderStatus.SENT, OrderStatus.IN_PREP, OrderStatus.READY):
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible de servir (statut actuel : {order.status})."
        )

    order.status = OrderStatus.SERVED
    order.served_at = dt.datetime.now(dt.timezone.utc)

    if order.type == OrderType.ROOM_SERVICE and order.room_id is not None:
        active_line = await session.scalar(
            select(ReservationRoom)
            .where(
                ReservationRoom.room_id == order.room_id,
                ReservationRoom.status == ReservationStatus.CHECKED_IN,
            )
            .order_by(ReservationRoom.checked_in_at.desc())
            .limit(1)
        )
        if active_line is None:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                "Cette chambre n'a pas de sejour en cours : aucun folio a debiter.",
            )
        folio = await session.scalar(
            select(Folio).where(
                Folio.reservation_room_id == active_line.id,
                Folio.status == FolioStatus.OPEN,
            )
        )
        if folio is None:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, "Aucun folio ouvert pour cette chambre."
            )

        session.add(
            FolioItem(
                folio_id=folio.id,
                category=ChargeCategory.FNB,
                label=f"Room service - commande {order.number}",
                quantity=1,
                unit_price=order.total,
                amount=order.total,
                tax_amount=order.tax_total,
                tax_rate=0,
                business_date=dt.date.today(),
                source_table="orders",
                source_id=order.id,
                posted_by=user.id,
                posted_at=dt.datetime.now(dt.timezone.utc),
            )
        )
        folio.charges_total += order.total
        folio.balance = folio.charges_total - folio.payments_total
        order.folio_id = folio.id

    await session.commit()
    await session.refresh(order, attribute_names=["items"])
    return order


@router.post("/{order_id}/cancel", response_model=OrderOut)
async def cancel_order(
    order_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.manage")),
) -> Order:
    order = await _get_order(session, order_id, user)
    if order.status in (OrderStatus.SERVED, OrderStatus.CANCELLED):
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Impossible d'annuler (statut actuel : {order.status})."
        )
    order.status = OrderStatus.CANCELLED
    order.cancelled_at = dt.datetime.now(dt.timezone.utc)
    for item in order.items:
        item.status = OrderStatus.CANCELLED
    await session.commit()
    await session.refresh(order, attribute_names=["items"])
    return order
