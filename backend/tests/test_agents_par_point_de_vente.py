"""Un agent ne voit que les points de vente auxquels il est rattache.

Rattachement par `user_outlets`, comme les roles. Un agent sans aucun
rattachement voit tout : sinon creer un agent le rendrait aveugle avant
qu'on ait pense a le rattacher. Une commande sur un point de vente non
rattache est refusee.
"""

from __future__ import annotations

import pytest

from app.models import MenuCategory, MenuItem, Outlet

pytestmark = pytest.mark.db

PASSWORD = "Agent1234!"


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def outlets_a(session, hotel_a):
    """Restaurant et bar, chacun avec un article a la carte."""
    hotel, _ = hotel_a
    restaurant = Outlet(hotel_id=hotel.id, code="REST", label="Restaurant", sort_order=1)
    bar = Outlet(hotel_id=hotel.id, code="BAR", label="Bar", sort_order=2)
    session.add_all([restaurant, bar])
    await session.flush()
    items = {}
    for outlet in (restaurant, bar):
        category = MenuCategory(hotel_id=hotel.id, outlet_id=outlet.id, label=outlet.label)
        session.add(category)
        await session.flush()
        item = MenuItem(
            hotel_id=hotel.id,
            code=f"{outlet.code}-1",
            label=f"Article {outlet.label}",
            menu_category_id=category.id,
            price=2_000,
        )
        session.add(item)
        items[outlet.code] = item
    await session.commit()
    return {"REST": restaurant, "BAR": bar}, items


async def _agent(client, auth, login, code, outlet_ids) -> tuple[dict, dict]:
    """Cree un agent avec les droits de test et le connecte."""
    resp = await client.post(
        "/api/v1/users",
        json={
            "employee_code": code,
            "first_name": "Agent",
            "last_name": code,
            "password": PASSWORD,
            "role_codes": ["TESTALL_HTA"],
            "outlet_ids": [str(i) for i in outlet_ids],
        },
        headers=auth,
    )
    assert resp.status_code == 201, resp.text
    login_resp = await client.post(
        "/api/v1/auth/login", json={"employee_code": code, "password": PASSWORD}
    )
    assert login_resp.status_code == 200, login_resp.text
    token = login_resp.json()["access_token"]
    return resp.json(), {"Authorization": f"Bearer {token}"}


async def _outlet_codes(client, auth) -> list[str]:
    resp = await client.get("/api/v1/outlets", headers=auth)
    assert resp.status_code == 200, resp.text
    return [o["code"] for o in resp.json()]


async def _order(client, auth, outlet, item):
    return await client.post(
        "/api/v1/orders",
        json={
            "outlet_id": str(outlet.id),
            "items": [{"menu_item_id": str(item.id), "quantity": 1}],
        },
        headers=auth,
    )


async def test_un_agent_rattache_au_bar_ne_voit_pas_le_restaurant(
    client, auth_a, login, outlets_a
):
    outlets, _ = outlets_a
    _, agent = await _agent(client, auth_a, login, "BAR01", [outlets["BAR"].id])
    assert await _outlet_codes(client, agent) == ["BAR"]


async def test_un_agent_sans_rattachement_voit_tout(client, auth_a, login, outlets_a):
    _, agent = await _agent(client, auth_a, login, "LIBRE01", [])
    assert await _outlet_codes(client, agent) == ["REST", "BAR"]


async def test_une_commande_sur_un_point_de_vente_non_rattache_est_refusee(
    client, auth_a, login, outlets_a
):
    outlets, items = outlets_a
    _, agent = await _agent(client, auth_a, login, "BAR02", [outlets["BAR"].id])

    refused = await _order(client, agent, outlets["REST"], items["REST"])
    assert refused.status_code == 403, refused.text
    accepted = await _order(client, agent, outlets["BAR"], items["BAR"])
    assert accepted.status_code == 201, accepted.text


async def test_get_users_porte_les_points_de_vente_et_patch_les_fixe(
    client, auth_a, login, outlets_a
):
    outlets, _ = outlets_a
    created, _ = await _agent(client, auth_a, login, "SERV01", [outlets["BAR"].id])
    assert created["outlet_ids"] == [str(outlets["BAR"].id)]

    listed = (await client.get("/api/v1/users", headers=auth_a)).json()
    assert {u["employee_code"]: u["outlet_ids"] for u in listed}["SERV01"] == [
        str(outlets["BAR"].id)
    ]

    url = f"/api/v1/users/{created['id']}"
    base = {"first_name": "Agent", "last_name": "SERV01", "role_codes": ["TESTALL_HTA"]}
    # Sans `outlet_ids`, les rattachements ne bougent pas.
    kept = await client.patch(url, json=base, headers=auth_a)
    assert kept.json()["outlet_ids"] == [str(outlets["BAR"].id)]
    moved = await client.patch(
        url, json={**base, "outlet_ids": [str(outlets["REST"].id)]}, headers=auth_a
    )
    assert moved.json()["outlet_ids"] == [str(outlets["REST"].id)]
    freed = await client.patch(url, json={**base, "outlet_ids": []}, headers=auth_a)
    assert freed.json()["outlet_ids"] == []


async def test_point_de_vente_d_un_autre_hotel_refuse(
    client, session, auth_a, hotel_b, outlets_a
):
    hotel, _ = hotel_b
    foreign = Outlet(hotel_id=hotel.id, code="BARB", label="Bar B")
    session.add(foreign)
    await session.commit()
    resp = await client.post(
        "/api/v1/users",
        json={
            "employee_code": "INTRUS",
            "first_name": "Agent",
            "last_name": "Intrus",
            "password": PASSWORD,
            "outlet_ids": [str(foreign.id)],
        },
        headers=auth_a,
    )
    assert resp.status_code == 422, resp.text
