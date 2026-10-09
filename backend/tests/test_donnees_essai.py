"""Les donnees d'essai se chargent, et se rechargent sans rien doubler."""

from __future__ import annotations

import pytest
from sqlalchemy import func, select

from app.db.donnees_essai import CARTES, ENTREES, POINTS, RAVITAILLEMENTS, charger
from app.db.seed import HOTEL, seed
from app.models import MenuItem, Outlet, StockLevel, StockLocation, StockMovement
from app.models.enums import OutletKind

pytestmark = pytest.mark.db


async def _nombre(session, modele, *conditions) -> int:
    return await session.scalar(select(func.count()).select_from(modele).where(*conditions))


async def test_charger_deux_fois_ne_double_rien(session):
    await seed(session)
    premier = await charger(session)
    second = await charger(session)

    assert premier["mouvements"] == len(ENTREES) + len(RAVITAILLEMENTS)
    assert second["mouvements"] == 0
    assert await _nombre(session, Outlet, Outlet.hotel_id == HOTEL) == len(POINTS)
    services = await _nombre(
        session, Outlet, Outlet.hotel_id == HOTEL, Outlet.kind == OutletKind.SERVICE
    )
    assert services == 7
    attendus = sum(len(a) for rubriques in CARTES.values() for _, a in rubriques)
    assert await _nombre(session, MenuItem, MenuItem.hotel_id == HOTEL) == attendus


async def test_la_mutzig_est_au_bar(session):
    await seed(session)
    await charger(session)

    bar = await session.scalar(select(Outlet).where(Outlet.hotel_id == HOTEL, Outlet.code == "BAR"))
    magasin = await session.scalar(select(StockLocation).where(StockLocation.outlet_id == bar.id))
    mutzig = await session.scalar(
        select(StockLevel)
        .join(StockMovement, StockMovement.product_id == StockLevel.product_id)
        .where(StockLevel.stock_location_id == magasin.id, StockMovement.reason == "Ravitaillement Bar / Lounge")
        .limit(1)
    )
    assert mutzig is not None and mutzig.quantity > 0

    economat = await session.scalar(
        select(StockLocation).where(StockLocation.hotel_id == HOTEL, StockLocation.is_central.is_(True))
    )
    total_mutzig = ENTREES["MUTZIG"] - sum(q for ref, _, q in RAVITAILLEMENTS if ref == "MUTZIG")
    niveaux = (
        await session.scalars(select(StockLevel).where(StockLevel.stock_location_id == economat.id))
    ).all()
    assert total_mutzig in [n.quantity for n in niveaux]
