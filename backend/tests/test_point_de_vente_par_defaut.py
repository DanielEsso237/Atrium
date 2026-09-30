"""Chaque hotel a d'office un point de vente « Restaurant ».

C'est lui qui portera plus tard la carte facturee sur l'ardoise d'une chambre.
Trois choses tiennent ici : le seed le cree sans doublon, le serveur refuse de
le desactiver ou de changer son code (la tablette le retrouve par son code),
et la carte (categories, articles) se renvoie sans doublon comme les points
de vente.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import func, select

from app.core.ids import uuid7
from app.db.seed import HOTEL, OUTLET_RESTO, OUTLET_RESTO_CODE, seed
from app.models import MenuCategory, MenuItem, Outlet
from app.services.outlets import DEFAULT_OUTLET_CODE

pytestmark = pytest.mark.db


def test_le_seed_et_le_serveur_parlent_du_meme_code():
    assert OUTLET_RESTO_CODE == DEFAULT_OUTLET_CODE == "RESTO"


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def resto_a(session, hotel_a):
    hotel, _ = hotel_a
    outlet = Outlet(
        hotel_id=hotel.id, code=DEFAULT_OUTLET_CODE, label="Restaurant", allows_room_charge=True
    )
    session.add(outlet)
    await session.commit()
    return outlet


async def _nombre_resto(session) -> int:
    return await session.scalar(
        select(func.count()).select_from(Outlet).where(Outlet.code == DEFAULT_OUTLET_CODE)
    )


# --- Le seed --------------------------------------------------------------------


async def test_le_seed_cree_le_point_de_vente_par_defaut(session):
    await seed(session)
    outlet = await session.get(Outlet, OUTLET_RESTO)
    assert outlet is not None
    assert outlet.hotel_id == HOTEL
    assert outlet.code == DEFAULT_OUTLET_CODE
    assert outlet.allows_room_charge is True
    assert outlet.sort_order == 0


async def test_rejouer_le_seed_ne_cree_pas_de_doublon_et_garde_le_libelle(session):
    await seed(session)
    outlet = await session.get(Outlet, OUTLET_RESTO)
    outlet.label = "Brasserie"
    await session.commit()

    await seed(session)

    assert await _nombre_resto(session) == 1
    await session.refresh(outlet)
    assert outlet.label == "Brasserie"


# --- La protection --------------------------------------------------------------


async def test_on_ne_desactive_pas_le_point_de_vente_par_defaut(client, auth_a, resto_a, session):
    resp = await client.patch(
        f"/api/v1/outlets/{resto_a.id}", json={"is_active": False}, headers=auth_a
    )
    assert resp.status_code == 409, resp.text
    assert "desactive" in resp.json()["detail"]
    await session.refresh(resto_a)
    assert resto_a.is_active is True


async def test_on_ne_change_pas_le_code_du_point_de_vente_par_defaut(client, auth_a, resto_a):
    resp = await client.patch(
        f"/api/v1/outlets/{resto_a.id}", json={"code": "AUTRE"}, headers=auth_a
    )
    assert resp.status_code == 409, resp.text


async def test_le_libelle_du_point_de_vente_par_defaut_reste_modifiable(client, auth_a, resto_a):
    resp = await client.patch(
        f"/api/v1/outlets/{resto_a.id}", json={"label": "Brasserie"}, headers=auth_a
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["label"] == "Brasserie"


async def test_un_autre_point_de_vente_se_desactive_toujours(client, auth_a, hotel_a, session):
    hotel, _ = hotel_a
    bar = Outlet(hotel_id=hotel.id, code="BAR", label="Bar")
    session.add(bar)
    await session.commit()
    resp = await client.patch(
        f"/api/v1/outlets/{bar.id}", json={"is_active": False}, headers=auth_a
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["is_active"] is False


# --- La carte, rejouable --------------------------------------------------------


async def test_une_categorie_renvoyee_ne_fait_pas_de_doublon(client, auth_a, resto_a, session):
    body = {"id": str(uuid7()), "outlet_id": str(resto_a.id), "label": "Plats"}
    premier = await client.post("/api/v1/menu-categories", json=body, headers=auth_a)
    second = await client.post("/api/v1/menu-categories", json=body, headers=auth_a)
    assert premier.status_code == 201, premier.text
    assert second.status_code == 200, second.text
    assert second.json()["id"] == body["id"]
    total = await session.scalar(select(func.count()).select_from(MenuCategory))
    assert total == 1


async def test_une_categorie_sans_id_recoit_celui_du_serveur(client, auth_a, resto_a):
    resp = await client.post(
        "/api/v1/menu-categories", json={"label": "Boissons"}, headers=auth_a
    )
    assert resp.status_code == 201, resp.text
    assert uuid.UUID(resp.json()["id"])


async def test_un_article_renvoye_ne_fait_pas_de_doublon(client, auth_a, resto_a, session):
    cat = (
        await client.post(
            "/api/v1/menu-categories",
            json={"outlet_id": str(resto_a.id), "label": "Plats"},
            headers=auth_a,
        )
    ).json()
    body = {
        "id": str(uuid7()),
        "code": "POULET",
        "label": "Poulet braise",
        "menu_category_id": cat["id"],
        "price": 3_500,
    }
    premier = await client.post("/api/v1/menu-items", json=body, headers=auth_a)
    second = await client.post("/api/v1/menu-items", json=body, headers=auth_a)
    assert premier.status_code == 201, premier.text
    assert second.status_code == 200, second.text
    assert second.json()["id"] == body["id"]
    total = await session.scalar(select(func.count()).select_from(MenuItem))
    assert total == 1


async def test_modifier_un_article_ne_touche_pas_a_son_id(client, auth_a, resto_a):
    cat = (
        await client.post(
            "/api/v1/menu-categories",
            json={"outlet_id": str(resto_a.id), "label": "Plats"},
            headers=auth_a,
        )
    ).json()
    item = (
        await client.post(
            "/api/v1/menu-items",
            json={"code": "RIZ", "label": "Riz", "menu_category_id": cat["id"], "price": 1_000},
            headers=auth_a,
        )
    ).json()
    resp = await client.patch(
        f"/api/v1/menu-items/{item['id']}",
        json={"code": "RIZ", "label": "Riz sauce", "menu_category_id": cat["id"], "price": 1_200},
        headers=auth_a,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["id"] == item["id"]
    assert resp.json()["price"] == 1_200
