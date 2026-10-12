"""Les ardoises du comptoir : consommer d'abord, payer a la fin.

Decision du 12 octobre. Au bar, un client prend une biere, puis un jus, et
demande sa note en partant. Son ardoise se paie au comptoir, se porte a la
chambre s'il est loge, ou s'annule avec un motif s'il est parti sans payer.
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
async def bar(session, hotel_a):
    hotel, _ = hotel_a
    outlet = Outlet(hotel_id=hotel.id, code="BAR", label="Bar", allows_room_charge=True)
    session.add(outlet)
    await session.commit()
    return str(outlet.id)


@pytest.fixture
async def agents(client, session, hotel_a, login, bar):
    hotel, _ = hotel_a
    await _agent(session, hotel, "BARMAN", COMPTOIR, [bar])
    await _agent(session, hotel, "RESPONSABLE", ["tab.cancel"])
    return {
        code: {"Authorization": f"Bearer {await login(client, code)}"}
        for code in ("BARMAN", "RESPONSABLE")
    }


@pytest.fixture
async def sejour(client, session, hotel_a, auth_a):
    """Awa Diallo en 101, plafond 30 000 ; rend (client, ardoise du sejour)."""
    hotel, _ = hotel_a
    room_type = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number="101", room_type_id=room_type.id)
    session.add(room)
    await session.commit()
    r = await client.post(
        "/api/v1/guests",
        json={"first_name": "Awa", "last_name": "Diallo", "credit_limit": 30_000},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text
    guest = r.json()["id"]
    res_id, line_id, folio_id = str(uuid7()), str(uuid7()), str(uuid7())
    r = await client.post(
        "/api/v1/reservations",
        json={
            "id": res_id,
            "guest_id": guest,
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
    assert r.status_code == 201, r.text
    r = await client.post(
        f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in",
        json={"room_id": str(room.id), "folio_id": folio_id},
        headers=auth_a,
    )
    assert r.status_code == 200, r.text
    return guest, folio_id


async def _ouvrir_caisse(client, auth, bar):
    r = await client.post(
        "/api/v1/cash-sessions", json={"opening_float": 0, "outlet_id": bar}, headers=auth
    )
    assert r.status_code in (200, 201), r.text
    return r.json()["id"]


async def _ouvrir_ardoise(client, auth, bar, numero=1, guest=None):
    corps = {"id": str(uuid7()), "outlet_id": bar, "tab_number": numero}
    if guest is not None:
        corps["guest_id"] = guest
    r = await client.post("/api/v1/outlet-tabs", json=corps, headers=auth)
    return r


async def _servir(client, auth, ardoise, bar, prix, label="Biere"):
    return await client.post(
        f"/api/v1/folios/{ardoise}/items",
        json={
            "id": str(uuid7()), "category": "FNB", "label": label,
            "unit_price": prix, "outlet_id": bar,
        },
        headers=auth,
    )


# --- Ouvrir ---------------------------------------------------------------------


async def test_sans_caisse_ouverte_pas_d_ardoise(client, agents, bar):
    r = await _ouvrir_ardoise(client, agents["BARMAN"], bar)

    assert r.status_code == 409


async def test_l_ardoise_s_ouvre_et_se_rejoue(client, agents, bar):
    await _ouvrir_caisse(client, agents["BARMAN"], bar)
    corps = {"id": str(uuid7()), "outlet_id": bar, "tab_number": 3}

    premiere = await client.post("/api/v1/outlet-tabs", json=corps, headers=agents["BARMAN"])
    seconde = await client.post("/api/v1/outlet-tabs", json=corps, headers=agents["BARMAN"])

    assert premiere.status_code == 201, premiere.text
    assert premiere.json()["status"] == "OPEN"
    assert premiere.json()["tab_number"] == 3
    assert premiere.json()["outlet_id"] == bar
    assert seconde.status_code == 200
    assert seconde.json()["id"] == corps["id"]


# --- Payer a la fin ---------------------------------------------------------------


async def test_une_biere_puis_un_jus_puis_la_note(client, agents, bar):
    caisse = await _ouvrir_caisse(client, agents["BARMAN"], bar)
    ardoise = (await _ouvrir_ardoise(client, agents["BARMAN"], bar)).json()["id"]
    assert (await _servir(client, agents["BARMAN"], ardoise, bar, 1_500)).status_code == 201
    assert (await _servir(client, agents["BARMAN"], ardoise, bar, 800, "Jus")).status_code == 201

    paiement = {"id": str(uuid7()), "method": "CASH", "amount": 2_300}
    r = await client.post(
        f"/api/v1/outlet-tabs/{ardoise}/settle",
        json={"payment": paiement},
        headers=agents["BARMAN"],
    )

    assert r.status_code == 200, r.text
    assert r.json()["status"] == "CLOSED"
    assert r.json()["balance"] == 0
    # Renvoye par la file : rien de plus.
    r = await client.post(
        f"/api/v1/outlet-tabs/{ardoise}/settle",
        json={"payment": paiement},
        headers=agents["BARMAN"],
    )
    assert r.status_code == 200, r.text
    # L'argent est dans le tiroir du bar.
    activite = await client.get(
        "/api/v1/outlet-activity?since=2000-01-01", headers=agents["BARMAN"]
    )
    assert [p["cash_session_id"] for p in activite.json()["payments"]] == [caisse]


async def test_le_paiement_couvre_le_total_ni_plus_ni_moins(client, agents, bar):
    await _ouvrir_caisse(client, agents["BARMAN"], bar)
    ardoise = (await _ouvrir_ardoise(client, agents["BARMAN"], bar)).json()["id"]
    await _servir(client, agents["BARMAN"], ardoise, bar, 1_500)

    r = await client.post(
        f"/api/v1/outlet-tabs/{ardoise}/settle",
        json={"payment": {"id": str(uuid7()), "method": "CASH", "amount": 1_000}},
        headers=agents["BARMAN"],
    )

    assert r.status_code == 409


# --- Porter a la chambre -------------------------------------------------------------


async def test_l_ardoise_du_client_loge_se_porte_a_sa_chambre(
    client, agents, bar, sejour, auth_a
):
    guest, chambre = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], bar)
    ardoise = (await _ouvrir_ardoise(client, agents["BARMAN"], bar, guest=guest)).json()["id"]
    await _servir(client, agents["BARMAN"], ardoise, bar, 1_500)
    await _servir(client, agents["BARMAN"], ardoise, bar, 1_000, "Jus")

    r = await client.post(
        f"/api/v1/outlet-tabs/{ardoise}/to-room",
        json={"room_folio_id": chambre},
        headers=agents["BARMAN"],
    )

    assert r.status_code == 200, r.text
    assert r.json()["status"] == "CLOSED"
    assert r.json()["items"] == []
    folio = (await client.get(f"/api/v1/folios/{chambre}", headers=auth_a)).json()
    bar_lignes = [i for i in folio["items"] if i["source_id"] == bar]
    # Les lignes changent d'ardoise sans changer de point de vente.
    assert {i["label"] for i in bar_lignes} == {"Biere", "Jus"}
    assert folio["balance"] == 2_500
    # Renvoye par la file : rien a refaire.
    r = await client.post(
        f"/api/v1/outlet-tabs/{ardoise}/to-room",
        json={"room_folio_id": chambre},
        headers=agents["BARMAN"],
    )
    assert r.status_code == 200


async def test_le_plafond_compte_l_ardoise_du_bar(client, agents, bar, sejour, auth_a):
    guest, chambre = sejour
    # 25 000 deja dus sur la chambre, plafond 30 000.
    r = await client.post(
        f"/api/v1/folios/{chambre}/items",
        json={"id": str(uuid7()), "category": "MINIBAR", "label": "Minibar", "unit_price": 25_000},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text
    await _ouvrir_caisse(client, agents["BARMAN"], bar)
    ardoise = (await _ouvrir_ardoise(client, agents["BARMAN"], bar, guest=guest)).json()["id"]

    assert (await _servir(client, agents["BARMAN"], ardoise, bar, 4_000)).status_code == 201
    # 25 000 + 4 000 + 2 000 : au-dela de 30 000, meme sur l'ardoise du bar.
    r = await _servir(client, agents["BARMAN"], ardoise, bar, 2_000, "Whisky")
    assert r.status_code == 409, r.text
    assert "Seuil" in r.text


# --- Annuler -------------------------------------------------------------------------


async def test_parti_sans_payer_un_responsable_annule(client, agents, bar):
    await _ouvrir_caisse(client, agents["BARMAN"], bar)
    ardoise = (await _ouvrir_ardoise(client, agents["BARMAN"], bar)).json()["id"]
    await _servir(client, agents["BARMAN"], ardoise, bar, 1_500)

    r = await client.post(
        f"/api/v1/outlet-tabs/{ardoise}/cancel",
        json={"reason": "Parti sans payer"},
        headers=agents["BARMAN"],
    )
    assert r.status_code == 403

    r = await client.post(
        f"/api/v1/outlet-tabs/{ardoise}/cancel",
        json={"reason": "Parti sans payer"},
        headers=agents["RESPONSABLE"],
    )
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "CLOSED"
    assert r.json()["balance"] == 0
    ligne = r.json()["items"][0]
    assert ligne["is_void"] is True
    assert ligne["void_reason"] == "Parti sans payer"


# --- Descente -------------------------------------------------------------------------


async def test_l_ardoise_ouverte_descend_aux_tablettes_du_bar(client, agents, bar):
    await _ouvrir_caisse(client, agents["BARMAN"], bar)
    ardoise = (await _ouvrir_ardoise(client, agents["BARMAN"], bar, numero=7)).json()["id"]

    activite = await client.get(
        "/api/v1/outlet-activity?since=2000-01-01", headers=agents["BARMAN"]
    )

    ardoises = {a["id"]: a for a in activite.json()["tabs"]}
    assert ardoises[ardoise]["tab_number"] == 7
    assert ardoises[ardoise]["status"] == "OPEN"
