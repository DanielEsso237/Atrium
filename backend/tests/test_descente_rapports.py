"""Ce qui redescend pour les rapports d'une tablette.

Une vente au comptoir est ouverte, encaissee et close en une requete : elle
ne passe jamais par la liste des ardoises ouvertes. Sans `closed_since` et
`GET /payments`, une autre tablette n'en saurait rien -- ni le chiffre, ni le
point de vente, ni l'agent, ni le moyen de paiement.
"""

from __future__ import annotations

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.models import User

from tests.test_client_de_passage import _agent, _vente

pytestmark = pytest.mark.db

LOIN_AVANT = "2000-01-01"
LOIN_APRES = "2999-01-01"


@pytest.fixture
async def comptoir(client, session, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(
        session,
        hotel,
        "BT_R",
        ["order.create", "folio.charge", "cash.session", "folio.read"],
    )
    agent = await session.scalar(select(User).where(User.employee_code == "BT_R"))
    return agent.id, {"Authorization": f"Bearer {await login(client, 'BT_R')}"}


@pytest.fixture
async def bar(session, hotel_a):
    from app.models.restaurant import Outlet

    hotel, _ = hotel_a
    outlet = Outlet(hotel_id=hotel.id, code="BAR", label="Bar", allows_room_charge=True)
    session.add(outlet)
    await session.commit()
    return str(outlet.id)


async def _vendre(client, bar, headers):
    folio_id = str(uuid7())
    r = await client.post(
        "/api/v1/folios/walk-in", json=_vente(bar, folio_id=folio_id), headers=headers
    )
    assert r.status_code == 201, r.text
    return folio_id


async def test_ardoise_close_redescend_avec_son_point_de_vente(client, bar, comptoir):
    agent_id, headers = comptoir
    folio_id = await _vendre(client, bar, headers)

    r = await client.get(
        "/api/v1/folios", params={"closed_since": LOIN_AVANT}, headers=headers
    )
    assert r.status_code == 200, r.text
    ardoise = next(f for f in r.json() if f["id"] == folio_id)
    for ligne in ardoise["items"]:
        assert ligne["source_table"] == "outlets"
        assert ligne["source_id"] == bar
        assert ligne["posted_by"] == str(agent_id)

    r = await client.get(
        "/api/v1/folios", params={"closed_since": LOIN_APRES}, headers=headers
    )
    assert all(f["id"] != folio_id for f in r.json())


async def test_encaissements_redescendent_avec_agent_et_journee(client, bar, comptoir):
    agent_id, headers = comptoir
    folio_id = await _vendre(client, bar, headers)

    r = await client.get("/api/v1/payments", params={"since": LOIN_AVANT}, headers=headers)
    assert r.status_code == 200, r.text
    paiement = next(p for p in r.json() if p["folio_id"] == folio_id)
    assert paiement["method"] == "CASH"
    assert paiement["amount"] == 6_000
    assert paiement["received_by"] == str(agent_id)
    assert paiement["business_date"] is not None

    r = await client.get("/api/v1/payments", params={"since": LOIN_APRES}, headers=headers)
    assert r.json() == []


async def test_encaissements_reserves_a_folio_read(client, session, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(session, hotel, "BT_S", ["order.create"])
    headers = {"Authorization": f"Bearer {await login(client, 'BT_S')}"}
    r = await client.get("/api/v1/payments", params={"since": LOIN_AVANT}, headers=headers)
    assert r.status_code == 403
