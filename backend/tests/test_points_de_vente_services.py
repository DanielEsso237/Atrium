"""Services, liste deroulante de commande (avec stock) et image d'un article."""

from __future__ import annotations

import pytest
from sqlalchemy import func, select

from app.core.config import settings
from app.db.seed import seed
from app.models import MenuCategory, MenuItem, Outlet, Product, StockLevel, StockLocation
from app.models.enums import OutletKind

pytestmark = pytest.mark.db

JPEG = b"\xff\xd8\xff\xe0" + b"photo" * 20


@pytest.fixture(autouse=True)
def dossier(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "uploads_dir", str(tmp_path))


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def bar(session, hotel_a):
    """Un bar : Flag (12 en stock), Castel (0), un cocktail non suivi, un article retire."""
    hotel, _ = hotel_a
    stk = StockLocation(hotel_id=hotel.id, code="STK-BAR", label="Stock bar")
    autre = StockLocation(hotel_id=hotel.id, code="STK-AUTRE", label="Autre")
    session.add_all([stk, autre])
    await session.flush()
    outlet = Outlet(hotel_id=hotel.id, code="BAR", label="Bar", stock_location_id=stk.id)
    flag = Product(hotel_id=hotel.id, reference="FLAG", label="Flag")
    castel = Product(hotel_id=hotel.id, reference="CASTEL", label="Castel")
    session.add_all([outlet, flag, castel])
    await session.flush()
    cat = MenuCategory(hotel_id=hotel.id, outlet_id=outlet.id, label="Boissons")
    session.add(cat)
    await session.flush()
    session.add_all(
        [
            MenuItem(hotel_id=hotel.id, code="FLAG", label="Flag", menu_category_id=cat.id,
                     price=1_500, product_id=flag.id),
            MenuItem(hotel_id=hotel.id, code="CASTEL", label="Castel", menu_category_id=cat.id,
                     price=1_500, product_id=castel.id),
            MenuItem(hotel_id=hotel.id, code="MOJITO", label="Mojito", menu_category_id=cat.id,
                     price=4_000),
            MenuItem(hotel_id=hotel.id, code="OFF", label="Retiré", menu_category_id=cat.id,
                     price=1_000, is_available=False),
            StockLevel(product_id=flag.id, stock_location_id=stk.id, quantity=12),
            # Dans un autre magasin : ne doit pas compter pour le bar.
            StockLevel(product_id=flag.id, stock_location_id=autre.id, quantity=100),
            StockLevel(product_id=castel.id, stock_location_id=stk.id, quantity=0),
        ]
    )
    await session.commit()
    return outlet


async def _disponibles(client, auth, outlet, **params):
    resp = await client.get(
        "/api/v1/menu-items/available",
        params={"outlet_id": str(outlet.id), **params},
        headers=auth,
    )
    assert resp.status_code == 200, resp.text
    return {i["label"]: i for i in resp.json()}


async def test_la_liste_donne_prix_et_stock_du_magasin_du_point_de_vente(client, auth_a, bar):
    items = await _disponibles(client, auth_a, bar)

    assert set(items) == {"Flag", "Mojito"}  # ni la rupture, ni l'article retire
    assert items["Flag"]["stock_quantity"] == 12  # pas 112 : l'autre magasin ne compte pas
    assert items["Flag"]["price"] == 1_500
    assert items["Mojito"]["stock_quantity"] is None
    assert items["Mojito"]["tracks_stock"] is False


async def test_la_rupture_peut_etre_demandee(client, auth_a, bar):
    items = await _disponibles(client, auth_a, bar, include_out_of_stock=True)

    assert items["Castel"]["stock_quantity"] == 0
    assert "Retiré" not in items


async def test_un_service_se_cree_et_se_filtre(client, auth_a):
    resp = await client.post(
        "/api/v1/outlets", json={"code": "SPA", "label": "Spa", "kind": "SERVICE"}, headers=auth_a
    )
    assert resp.status_code == 201, resp.text
    await client.post("/api/v1/outlets", json={"code": "BAR", "label": "Bar"}, headers=auth_a)

    services = (await client.get("/api/v1/outlets?kind=SERVICE", headers=auth_a)).json()
    assert [o["code"] for o in services] == ["SPA"]
    tous = (await client.get("/api/v1/outlets", headers=auth_a)).json()
    assert {o["code"]: o["kind"] for o in tous} == {"SPA": "SERVICE", "BAR": "OUTLET"}


async def test_un_magasin_d_un_autre_hotel_est_refuse(client, session, auth_a, hotel_b):
    hotel, _ = hotel_b
    etranger = StockLocation(hotel_id=hotel.id, code="X", label="X")
    session.add(etranger)
    await session.commit()

    resp = await client.post(
        "/api/v1/outlets",
        json={"code": "BAR", "label": "Bar", "stock_location_id": str(etranger.id)},
        headers=auth_a,
    )

    assert resp.status_code == 422, resp.text


async def test_le_point_de_vente_par_defaut_ne_devient_pas_un_service(client, session, auth_a, hotel_a):
    hotel, _ = hotel_a
    resto = Outlet(hotel_id=hotel.id, code="RESTO", label="Restaurant")
    session.add(resto)
    await session.commit()

    resp = await client.patch(
        f"/api/v1/outlets/{resto.id}", json={"kind": "SERVICE"}, headers=auth_a
    )

    assert resp.status_code == 409, resp.text


async def test_l_image_d_un_article_remonte_dans_sa_fiche(client, auth_a, bar, session):
    item = await session.scalar(select(MenuItem).where(MenuItem.code == "MOJITO"))
    piece = "01920000-0000-7000-8000-00000000c001"

    resp = await client.put(
        f"/api/v1/attachments/{piece}",
        data={"entity_table": "menu_items", "entity_id": str(item.id), "kind": "PHOTO"},
        files={"file": ("mojito.jpg", JPEG, "image/jpeg")},
        headers=auth_a,
    )

    assert resp.status_code == 201, resp.text
    items = await _disponibles(client, auth_a, bar)
    assert items["Mojito"]["photo_url"] == f"/api/v1/attachments/{piece}/file"
    fichier = await client.get(f"/api/v1/attachments/{piece}/file", headers=auth_a)
    assert fichier.content == JPEG


async def test_l_image_d_un_service_remonte_dans_sa_fiche(client, auth_a):
    spa = (
        await client.post(
            "/api/v1/outlets", json={"code": "SPA", "label": "Spa", "kind": "SERVICE"}, headers=auth_a
        )
    ).json()
    piece = "01920000-0000-7000-8000-00000000c002"

    resp = await client.put(
        f"/api/v1/attachments/{piece}",
        data={"entity_table": "outlets", "entity_id": spa["id"], "kind": "PHOTO"},
        files={"file": ("spa.jpg", JPEG, "image/jpeg")},
        headers=auth_a,
    )

    assert resp.status_code == 201, resp.text
    services = (await client.get("/api/v1/outlets?kind=SERVICE", headers=auth_a)).json()
    assert services[0]["photo_url"] == f"/api/v1/attachments/{piece}/file"


async def test_modifier_un_article_sans_product_id_garde_le_lien_avec_le_stock(
    client, auth_a, bar, session
):
    item = await session.scalar(select(MenuItem).where(MenuItem.code == "FLAG"))
    lien = item.product_id

    resp = await client.patch(
        f"/api/v1/menu-items/{item.id}",
        json={"code": "FLAG", "label": "Flag 65 cl", "menu_category_id": str(item.menu_category_id),
              "price": 1_600},
        headers=auth_a,
    )

    assert resp.status_code == 200, resp.text
    assert resp.json()["product_id"] == str(lien)


async def test_le_seed_cree_les_services_sans_doublon(session):
    await seed(session)
    await seed(session)
    services = set(
        (
            await session.execute(select(Outlet.code).where(Outlet.kind == OutletKind.SERVICE))
        ).scalars()
    )
    assert services == {"SPA", "PISCINE", "FITNESS", "CONFERENCE", "BANQUET"}
    total = await session.scalar(select(func.count()).select_from(MenuItem))
    stock = await session.scalar(select(func.sum(StockLevel.quantity)))
    await seed(session)
    assert await session.scalar(select(func.count()).select_from(MenuItem)) == total
    assert await session.scalar(select(func.sum(StockLevel.quantity))) == stock