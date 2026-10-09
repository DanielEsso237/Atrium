"""Ce qu'un mouvement change aux stocks, et la sortie a la vente.

Partage par la route des mouvements et par les ventes (ardoise d'une chambre,
client de passage) : une seule facon de compter, sinon les deux divergeraient
au premier changement.

Le stock peut passer sous zero (decision du 8 octobre : on vend, et l'econome
est alerte). Un refus ici bloquerait la file d'envoi d'une tablette.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.ids import uuid7
from app.models import MenuItem, Outlet, StockLevel, StockMovement
from app.models.enums import StockMovementStatus, StockMovementType
from app.services.stock_locations import ensure_outlet_location


async def apply_delta(
    session: AsyncSession, product_id: uuid.UUID, location_id: uuid.UUID, delta: int
) -> None:
    """Met a jour le compteur `stock_levels`, quitte a passer sous zero.

    `stock_movements` reste la source de verite ; ce compteur ne sert qu'a
    afficher un stock sans reagreger tout l'historique.
    """
    level = await session.scalar(
        select(StockLevel).where(
            StockLevel.product_id == product_id, StockLevel.stock_location_id == location_id
        )
    )
    now = dt.datetime.now(dt.timezone.utc)
    if level is None:
        session.add(
            StockLevel(
                product_id=product_id,
                stock_location_id=location_id,
                quantity=delta,
                last_movement_at=now,
            )
        )
        # Visible des la requete suivante de la meme transaction : deux
        # lignes d'une meme vente sur un meme produit doivent s'additionner.
        await session.flush()
    else:
        level.quantity += delta
        level.last_movement_at = now


async def apply_movement(session: AsyncSession, m: StockMovement) -> None:
    """Ce que le mouvement change aux stocks."""
    if m.type == StockMovementType.TRANSFER:
        await apply_delta(session, m.product_id, m.stock_location_id, -m.quantity)
        await apply_delta(session, m.product_id, m.counterpart_location_id, m.quantity)
    elif m.type == StockMovementType.ADJUSTMENT:
        # Delta signe, deja dans le bon sens.
        await apply_delta(session, m.product_id, m.stock_location_id, m.quantity)
    elif m.type in (StockMovementType.IN, StockMovementType.RETURN):
        await apply_delta(session, m.product_id, m.stock_location_id, m.quantity)
    else:  # OUT, LOSS
        await apply_delta(session, m.product_id, m.stock_location_id, -m.quantity)


async def deduct_for_sale(
    session: AsyncSession,
    *,
    hotel_id: uuid.UUID,
    outlet_id: uuid.UUID | None,
    menu_item_id: uuid.UUID | None,
    quantity: int,
    folio_item_id: uuid.UUID,
    by: uuid.UUID | None,
) -> StockMovement | None:
    """Fait sortir du stock du point de vente ce qu'une ligne vendue consomme.

    Rien si la vente ne dit pas son article ou son point de vente, ou si
    l'article n'est relie a aucun produit (un plat du jour, un service) :
    tout ne se stocke pas. A appeler une seule fois par ligne -- les routes
    de vente rendent une ligne deja enregistree avant d'arriver ici.
    """
    if outlet_id is None or menu_item_id is None or quantity <= 0:
        return None
    article = await session.get(MenuItem, menu_item_id)
    if article is None or article.hotel_id != hotel_id or article.product_id is None:
        return None
    outlet = await session.get(Outlet, outlet_id)
    if outlet is None or outlet.hotel_id != hotel_id:
        return None
    magasin = await ensure_outlet_location(session, outlet)
    movement = StockMovement(
        id=uuid7(),
        hotel_id=hotel_id,
        product_id=article.product_id,
        stock_location_id=magasin.id,
        type=StockMovementType.OUT,
        quantity=quantity * article.stock_quantity,
        reason=f"Vente : {article.label}",
        source_table="folio_items",
        source_id=folio_item_id,
        moved_at=dt.datetime.now(dt.timezone.utc),
        moved_by=by,
        status=StockMovementStatus.APPROVED,
    )
    session.add(movement)
    await apply_movement(session, movement)
    return movement
