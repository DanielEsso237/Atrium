"""Creer un agent depuis l'administration de la tablette.

Un nom, un code, un PIN : la reception se connecte au PIN. La creation part
de la file d'une tablette, donc elle accepte l'id de la tablette et se
rejoue sans doublon. A la connexion, les roles portent leurs permissions :
c'est ce qui permet a n'importe quelle tablette d'enregistrer les droits
d'un agent qu'elle ne connaissait pas.
"""

from __future__ import annotations

import pytest

from app.core.ids import uuid7

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


def _agent(**extra) -> dict:
    return {
        "id": str(uuid7()),
        "employee_code": "BAR01",
        "first_name": "Ines",
        "last_name": "Mbarga",
        "pin": "4321",
        **extra,
    }


async def test_un_agent_cree_avec_un_pin_se_connecte_au_pin(client, auth_a):
    resp = await client.post("/api/v1/users", json=_agent(), headers=auth_a)
    assert resp.status_code == 201, resp.text
    assert resp.json()["must_change_password"] is False

    login = await client.post(
        "/api/v1/auth/login", json={"employee_code": "BAR01", "password": "4321"}
    )

    assert login.status_code == 200, login.text


async def test_un_renvoi_ne_cree_pas_un_second_agent(client, auth_a):
    corps = _agent()

    premier = await client.post("/api/v1/users", json=corps, headers=auth_a)
    second = await client.post("/api/v1/users", json=corps, headers=auth_a)

    assert premier.status_code == 201, premier.text
    assert second.status_code == 200, second.text
    assert second.json()["id"] == corps["id"]


@pytest.mark.parametrize("pin", ["12", "abcd", "123456789"])
async def test_un_pin_mal_forme_est_refuse(client, auth_a, pin):
    resp = await client.post("/api/v1/users", json=_agent(pin=pin), headers=auth_a)

    assert resp.status_code == 422


async def test_sans_pin_ni_mot_de_passe_refuse(client, auth_a):
    corps = _agent()
    del corps["pin"]

    resp = await client.post("/api/v1/users", json=corps, headers=auth_a)

    assert resp.status_code == 422


async def test_la_connexion_dit_les_permissions_de_chaque_role(client, auth_a):
    me = (await client.get("/api/v1/auth/me", headers=auth_a)).json()

    permissions = {p for r in me["roles"] for p in r["permissions"]}
    assert "users.write" in permissions
    assert "guests.read" in permissions
