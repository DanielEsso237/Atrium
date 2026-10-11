"""Le client de passage : il consomme au comptoir, paie et s'en va.

`POST /folios/walk-in` cree l'ardoise, porte les consommations, encaisse
et clot en une requete. Le comptoir (order.create + folio.charge +
cash.session) la fait sans folio.write.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import Permission, Role, RolePermission, User, UserRole
from app.models.restaurant import Outlet

pytestmark = pytest.mark.db


async def _agent(session, hotel, code, permissions):
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
        first_name="Ines",
        last_name="Mbarga",
        password_hash=hash_secret("Test1234!"),
        is_active=True,
        must_change_password=False,
    )
    session.add(agent)
    await session.flush()
    session.add(UserRole(user_id=agent.id, role_id=role.id))
    await session.commit()


@pytest.fixture
async def bar(session, hotel_a):
    hotel, _ = hotel_a
    outlet = Outlet(hotel_id=hotel.id, code="BAR", label="Bar", allows_room_charge=True)
    session.add(outlet)
    await session.commit()
    return str(outlet.id)


@pytest.fixture
async def auth_comptoir(client, session, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(session, hotel, "BT_P", ["order.create", "folio.charge", "cash.session"])
    auth = {"Authorization": f"Bearer {await login(client, 'BT_P')}"}
    # Encaisser exige une caisse ouverte (409 sinon).
    r = await client.post("/api/v1/cash-sessions", json={"opening_float": 0}, headers=auth)
    assert r.status_code in (200, 201), r.text
    return auth


def _vente(bar, montant=6_000, folio_id=None):
    return {
        "id": folio_id or str(uuid7()),
        "outlet_id": bar,
        "items": [
            {"id": str(uuid7()), "category": "FNB", "label": "Biere", "quantity": 2, "unit_price": 1_500},
            {"id": str(uuid7()), "category": "FNB", "label": "Brochettes", "unit_price": 3_000},
        ],
        "payment": {"id": str(uuid7()), "method": "CASH", "amount": montant},
    }


async def test_vente_encaissee_et_close(client, bar, auth_comptoir):
    r = await client.post("/api/v1/folios/walk-in", json=_vente(bar), headers=auth_comptoir)
    assert r.status_code == 201, r.text
    folio = r.json()
    assert folio["type"] == "WALK_IN"
    assert folio["status"] == "CLOSED"
    assert folio["charges_total"] == 6_000
    assert folio["balance"] == 0


async def test_rejeu_ne_vend_pas_deux_fois(client, bar, auth_comptoir):
    vente = _vente(bar)
    await client.post("/api/v1/folios/walk-in", json=vente, headers=auth_comptoir)
    r = await client.post("/api/v1/folios/walk-in", json=vente, headers=auth_comptoir)
    assert r.status_code == 200
    assert r.json()["charges_total"] == 6_000


async def test_le_paiement_doit_couvrir_le_total(client, bar, auth_comptoir):
    r = await client.post(
        "/api/v1/folios/walk-in", json=_vente(bar, montant=5_000), headers=auth_comptoir
    )
    assert r.status_code == 409


async def test_caisse_fermee_pas_de_vente(client, session, hotel_a, login, bar):
    # Le droit sans la caisse ouverte : la vente n'a pas de tiroir ou tomber.
    hotel, _ = hotel_a
    await _agent(session, hotel, "BT_F", ["order.create", "folio.charge", "cash.session"])
    auth = {"Authorization": f"Bearer {await login(client, 'BT_F')}"}
    r = await client.post("/api/v1/folios/walk-in", json=_vente(bar), headers=auth)
    assert r.status_code == 409
    assert "caisse" in r.json()["detail"]


async def test_sans_caisse_pas_de_vente(client, session, hotel_a, login, bar):
    hotel, _ = hotel_a
    await _agent(session, hotel, "BT_N", ["order.create", "folio.charge"])
    auth = {"Authorization": f"Bearer {await login(client, 'BT_N')}"}
    r = await client.post("/api/v1/folios/walk-in", json=_vente(bar), headers=auth)
    assert r.status_code == 403
