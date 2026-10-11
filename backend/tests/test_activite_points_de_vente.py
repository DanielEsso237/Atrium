"""L'activite d'un point de vente descend a ses agents, et a eux seuls.

Un agent de point de vente ne lit pas les ardoises de l'hotel : son tableau
de bord ne voyait que ce que sa tablette avait vendu. `GET /outlet-activity`
lui donne les lignes, encaissements et tiroirs de ses points de vente, sur
tous les postes -- pas les ardoises entieres, ni ce que le client a pris
ailleurs.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import (
    Permission,
    Role,
    RolePermission,
    Room,
    RoomType,
    User,
    UserOutlet,
    UserRole,
)
from app.models.restaurant import Outlet

pytestmark = pytest.mark.db

COMPTOIR = ["order.read", "order.create", "folio.charge", "cash.session"]
DEPUIS = "2000-01-01"


async def _agent(session, hotel, code, permissions, outlets=()):
    role = Role(id=uuid.uuid4(), code=f"R_{code}", label=code)
    session.add(role)
    await session.flush()
    for p in permissions:
        perm = await session.scalar(select(Permission).where(Permission.code == p))
        if perm is None:
            perm = Permission(id=uuid.uuid4(), code=p, label=p, module=p.split(".")[0])
            session.add(perm)
            await session.flush()
        session.add(RolePermission(role_id=role.id, permission_id=perm.id))
    agent = User(
        id=uuid.uuid4(),
        hotel_id=hotel.id,
        employee_code=code,
        first_name="Agent",
        last_name=code,
        password_hash=hash_secret("Test1234!"),
        is_active=True,
        must_change_password=False,
    )
    session.add(agent)
    await session.flush()
    session.add(UserRole(user_id=agent.id, role_id=role.id))
    for outlet in outlets:
        session.add(UserOutlet(user_id=agent.id, outlet_id=uuid.UUID(outlet)))
    await session.commit()


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def points(session, hotel_a):
    hotel, _ = hotel_a
    bar = Outlet(hotel_id=hotel.id, code="BAR", label="Bar", allows_room_charge=True)
    resto = Outlet(hotel_id=hotel.id, code="REST", label="Restaurant", allows_room_charge=True)
    session.add_all([bar, resto])
    await session.commit()
    return {"bar": str(bar.id), "resto": str(resto.id)}


@pytest.fixture
async def agents(client, session, hotel_a, login, points):
    """Deux barmen, un serveur du restaurant, une reception sans rattachement."""
    hotel, _ = hotel_a
    await _agent(session, hotel, "BARMAN", COMPTOIR, [points["bar"]])
    await _agent(session, hotel, "BARMAN2", COMPTOIR, [points["bar"]])
    await _agent(session, hotel, "SERVEUR", COMPTOIR, [points["resto"]])
    await _agent(session, hotel, "RECEP", ["order.read", "folio.read"])
    await _agent(session, hotel, "MENAGE", ["housekeeping.read"])
    return {
        code: {"Authorization": f"Bearer {await login(client, code)}"}
        for code in ("BARMAN", "BARMAN2", "SERVEUR", "RECEP", "MENAGE")
    }


@pytest.fixture
async def ardoise(client, session, hotel_a, auth_a):
    """L'ardoise ouverte d'un client loge en 101."""
    hotel, _ = hotel_a
    room_type = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number="101", room_type_id=room_type.id)
    session.add(room)
    await session.commit()
    guest = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth_a
        )
    ).json()
    res_id, line_id, folio_id = str(uuid7()), str(uuid7()), str(uuid7())
    await client.post(
        "/api/v1/reservations",
        json={
            "id": res_id,
            "guest_id": guest["id"],
            "rooms": [
                {
                    "id": line_id,
                    "room_type_id": str(room_type.id),
                    "arrival_date": str(dt.date(2030, 3, 10)),
                    "departure_date": str(dt.date(2030, 3, 11)),
                }
            ],
        },
        headers=auth_a,
    )
    resp = await client.post(
        f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in",
        json={"room_id": str(room.id), "folio_id": folio_id},
        headers=auth_a,
    )
    assert resp.status_code == 200, resp.text
    return folio_id


async def _ouvrir(client, auth, outlet):
    r = await client.post(
        "/api/v1/cash-sessions", json={"opening_float": 0, "outlet_id": outlet}, headers=auth
    )
    assert r.status_code in (200, 201), r.text
    return r.json()["id"]


async def _porter(client, auth, folio, outlet, montant, label="Biere"):
    r = await client.post(
        f"/api/v1/folios/{folio}/items",
        json={
            "id": str(uuid7()), "category": "FNB", "label": label,
            "unit_price": montant, "outlet_id": outlet,
        },
        headers=auth,
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _vendre(client, auth, outlet, montant):
    r = await client.post(
        "/api/v1/folios/walk-in",
        json={
            "id": str(uuid7()),
            "outlet_id": outlet,
            "items": [{"id": str(uuid7()), "category": "FNB", "label": "Soda", "unit_price": montant}],
            "payment": {"id": str(uuid7()), "method": "CASH", "amount": montant},
        },
        headers=auth,
    )
    assert r.status_code == 201, r.text
    return r.json()


@pytest.fixture
async def soiree(client, auth_a, points, agents, ardoise):
    """Le bar porte une biere en 101 et vend un soda au comptoir (deux
    barmen, deux tiroirs) ; le restaurant porte un plat en 101 ; la reception
    porte un minibar, sans point de vente."""
    caisse_bar = await _ouvrir(client, agents["BARMAN"], points["bar"])
    caisse_bar2 = await _ouvrir(client, agents["BARMAN2"], points["bar"])
    caisse_resto = await _ouvrir(client, agents["SERVEUR"], points["resto"])
    biere = await _porter(client, agents["BARMAN"], ardoise, points["bar"], 3_000)
    soda = await _vendre(client, agents["BARMAN2"], points["bar"], 1_500)
    plat = await _porter(client, agents["SERVEUR"], ardoise, points["resto"], 8_000, "Plat")
    r = await client.post(
        f"/api/v1/folios/{ardoise}/items",
        json={"id": str(uuid7()), "category": "MINIBAR", "label": "Minibar", "unit_price": 2_000},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text
    return {
        "biere": biere,
        "soda": soda["items"][0]["id"],
        "soda_folio": soda["id"],
        "plat": plat,
        "caisses_bar": {caisse_bar, caisse_bar2},
        "caisse_resto": caisse_resto,
    }


async def _activite(client, auth):
    r = await client.get(f"/api/v1/outlet-activity?since={DEPUIS}", headers=auth)
    assert r.status_code == 200, r.text
    return r.json()


# --- Ce que voit le bar ------------------------------------------------------------


async def test_le_barman_voit_les_ventes_du_bar_sur_tous_les_postes(
    client, agents, soiree, ardoise
):
    activite = await _activite(client, agents["BARMAN"])

    ventes = {v["id"]: v for v in activite["sales"]}
    # La biere qu'il a portee, et le soda vendu par son collegue.
    assert set(ventes) == {soiree["biere"], soiree["soda"]}
    assert ventes[soiree["biere"]]["folio_id"] == ardoise
    assert ventes[soiree["biere"]]["folio_type"] == "GUEST"
    assert ventes[soiree["soda"]]["folio_type"] == "WALK_IN"
    assert all(v["posted_at"] is not None for v in ventes.values())


async def test_le_barman_ne_voit_ni_le_restaurant_ni_le_reste_de_l_ardoise(
    client, agents, soiree
):
    activite = await _activite(client, agents["BARMAN"])

    labels = {v["label"] for v in activite["sales"]}
    assert "Plat" not in labels
    # La nuitee et le minibar sont sur la meme ardoise : pas son affaire.
    assert "Minibar" not in labels
    assert all(v["category"] != "ROOM" for v in activite["sales"])
    # Ni totaux ni lignes de l'ardoise : l'en-tete seul.
    assert all("items" not in v and "balance" not in v for v in activite["sales"])


async def test_le_barman_voit_les_tiroirs_du_bar_meme_ceux_d_un_collegue(
    client, agents, soiree
):
    activite = await _activite(client, agents["BARMAN"])

    assert {c["id"] for c in activite["cash_sessions"]} == soiree["caisses_bar"]
    # L'encaissement du soda, passe dans le tiroir du collegue.
    assert [p["folio_id"] for p in activite["payments"]] == [soiree["soda_folio"]]


# --- Le perimetre ------------------------------------------------------------------


async def test_sans_rattachement_la_reception_voit_tous_les_points_de_vente(
    client, agents, soiree
):
    activite = await _activite(client, agents["RECEP"])

    assert {v["id"] for v in activite["sales"]} == {
        soiree["biere"], soiree["soda"], soiree["plat"],
    }
    assert {c["id"] for c in activite["cash_sessions"]} == soiree["caisses_bar"] | {
        soiree["caisse_resto"]
    }


async def test_un_autre_hotel_ne_voit_rien(client, hotel_b, login, soiree):
    auth_b = {"Authorization": f"Bearer {await login(client, 'ADMIN_B')}"}

    activite = await _activite(client, auth_b)

    assert activite == {"sales": [], "payments": [], "cash_sessions": []}


async def test_sans_le_droit_des_commandes_refuse(client, agents, soiree):
    r = await client.get(f"/api/v1/outlet-activity?since={DEPUIS}", headers=agents["MENAGE"])

    assert r.status_code == 403


async def test_une_vente_d_avant_la_fenetre_ne_descend_pas(client, agents, soiree):
    r = await client.get("/api/v1/outlet-activity?since=2999-01-01", headers=agents["BARMAN"])

    assert r.status_code == 200, r.text
    assert r.json()["sales"] == []


# --- La correction : portee a la chambre, la vente garde son point de vente ------


async def test_portee_a_la_chambre_la_ligne_garde_son_point_de_vente(
    client, auth_a, points, soiree, ardoise
):
    r = await client.get(f"/api/v1/folios/{ardoise}", headers=auth_a)
    assert r.status_code == 200, r.text
    lignes = {i["id"]: i for i in r.json()["items"]}

    assert lignes[soiree["biere"]]["source_table"] == "outlets"
    assert lignes[soiree["biere"]]["source_id"] == points["bar"]
    assert lignes[soiree["plat"]]["source_id"] == points["resto"]
