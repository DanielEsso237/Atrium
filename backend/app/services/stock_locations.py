"""L'economat et le magasin de chaque point de vente.

Chaque point de vente a son stock : c'est la qu'une vente fait sortir les
produits, et la que l'economat envoie ses ravitaillements. Le magasin nait
avec le point de vente, dans la meme transaction -- un point de vente sans
magasin aurait des ventes sans stock ou sortir.

Les deux fonctions sont idempotentes : rappelees, elles rendent le magasin
existant au lieu d'en creer un second.
"""

from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.ids import uuid7
from app.models import Outlet, StockLocation

ECONOMAT_CODE = "ECONOMAT"


async def ensure_central(session: AsyncSession, hotel_id: uuid.UUID) -> StockLocation:
    """L'economat de l'hotel, cree s'il n'existe pas.

    Un magasin deja nomme ECONOMAT, cree a la main avant cette regle, devient
    l'economat plutot que d'en voir naitre un second.
    """
    central = await session.scalar(
        select(StockLocation).where(
            StockLocation.hotel_id == hotel_id, StockLocation.is_central.is_(True)
        )
    )
    if central is not None:
        return central
    central = await session.scalar(
        select(StockLocation).where(
            StockLocation.hotel_id == hotel_id, StockLocation.code == ECONOMAT_CODE
        )
    )
    if central is None:
        central = StockLocation(
            id=uuid7(), hotel_id=hotel_id, code=ECONOMAT_CODE, label="Économat", sort_order=0
        )
        session.add(central)
    central.is_central = True
    await session.flush()
    return central


async def ensure_outlet_location(session: AsyncSession, outlet: Outlet) -> StockLocation:
    """Le magasin d'un point de vente, cree s'il n'existe pas.

    Il prend le code et le libelle du point de vente : sur l'ecran des stocks,
    « Bar » se reconnait. Un magasin libre de meme code, cree avant cette
    regle, lui est rattache plutot que doublonne.
    """
    location = await session.scalar(
        select(StockLocation).where(StockLocation.outlet_id == outlet.id)
    )
    if location is not None:
        return location
    location = await session.scalar(
        select(StockLocation).where(
            StockLocation.hotel_id == outlet.hotel_id,
            StockLocation.code == outlet.code,
            StockLocation.outlet_id.is_(None),
            StockLocation.is_central.is_(False),
        )
    )
    if location is None:
        location = StockLocation(
            id=uuid7(),
            hotel_id=outlet.hotel_id,
            code=outlet.code,
            label=outlet.label,
            sort_order=outlet.sort_order + 1,
        )
        session.add(location)
    location.outlet_id = outlet.id
    await session.flush()
    return location
