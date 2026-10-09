"""L'economat, et le magasin de chaque point de vente.

L'economat est le stock principal ; chaque point de vente a son magasin, ne
avec lui. Un magasin manquant laisserait une vente sans stock ou sortir, et un
magasin en double couperait le stock d'un point de vente en deux.
"""

from __future__ import annotations

import pytest
from sqlalchemy import func, select

from app.core.ids import uuid7
from app.db.seed import HOTEL, OUTLET_RESTO, seed
from app.models import StockLocation
from app.services.stock_locations import ECONOMAT_CODE, ensure_central

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def _magasins(client, auth) -> list[dict]:
    r = await client.get("/api/v1/stock-locations", headers=auth)
    assert r.status_code == 200, r.text
    return r.json()


async def test_un_point_de_vente_nait_avec_son_magasin(client, auth_a):
    r = await client.post(
        "/api/v1/outlets", json={"code": "BAR", "label": "Bar"}, headers=auth_a
    )
    assert r.status_code == 201, r.text
    bar = r.json()

    magasin = [m for m in await _magasins(client, auth_a) if m["outlet_id"] == bar["id"]]
    assert len(magasin) == 1
    assert (magasin[0]["code"], magasin[0]["label"]) == ("BAR", "Bar")
    assert magasin[0]["is_central"] is False


async def test_un_renvoi_ne_double_pas_le_magasin(client, auth_a):
    corps = {"id": str(uuid7()), "code": "BOITE", "label": "Boite de nuit"}
    await client.post("/api/v1/outlets", json=corps, headers=auth_a)
    r = await client.post("/api/v1/outlets", json=corps, headers=auth_a)
    assert r.status_code == 200

    magasins = [m for m in await _magasins(client, auth_a) if m["outlet_id"] == corps["id"]]
    assert len(magasins) == 1


async def test_le_magasin_suit_le_nom_du_point_de_vente(client, auth_a):
    bar = (
        await client.post("/api/v1/outlets", json={"code": "BAR", "label": "Bar"}, headers=auth_a)
    ).json()
    r = await client.patch(
        f"/api/v1/outlets/{bar['id']}", json={"label": "Bar de la piscine"}, headers=auth_a
    )
    assert r.status_code == 200, r.text

    magasin = next(m for m in await _magasins(client, auth_a) if m["outlet_id"] == bar["id"])
    assert magasin["label"] == "Bar de la piscine"


async def test_un_seul_economat_par_hotel(session, hotel_a):
    hotel, _ = hotel_a
    premier = await ensure_central(session, hotel.id)
    second = await ensure_central(session, hotel.id)
    await session.commit()

    assert premier.id == second.id
    assert premier.code == ECONOMAT_CODE
    nombre = await session.scalar(
        select(func.count())
        .select_from(StockLocation)
        .where(StockLocation.hotel_id == hotel.id, StockLocation.is_central.is_(True))
    )
    assert nombre == 1


async def test_le_seed_pose_l_economat_et_le_magasin_du_restaurant(session):
    await seed(session)
    await seed(session)  # rejoue : rien en double

    economats = (
        await session.scalars(
            select(StockLocation).where(
                StockLocation.hotel_id == HOTEL, StockLocation.is_central.is_(True)
            )
        )
    ).all()
    assert len(economats) == 1
    resto = (
        await session.scalars(select(StockLocation).where(StockLocation.outlet_id == OUTLET_RESTO))
    ).all()
    assert len(resto) == 1
