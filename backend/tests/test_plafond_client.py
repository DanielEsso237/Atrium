"""Le plafond d'un client est fixe par l'administration (decision du 29/09).

La reception gere les fiches (`guests.write`) mais pas le plafond : seul
`users.write` l'ecrit. Sa fiche client ne l'envoie jamais, ce refus ne peut
donc pas bloquer sa file.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.core.security import hash_secret
from app.models import Guest, Permission, Role, RolePermission, User, UserRole

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def auth_reception(client, session, hotel_a, login):
    """Un agent de reception : il ecrit les fiches, pas les plafonds."""
    hotel, _ = hotel_a
    role = Role(id=uuid.uuid4(), code="RECEP_TEST", label="Reception test")
    session.add(role)
    await session.flush()
    for code in ("guests.read", "guests.write"):
        perm = await session.scalar(select(Permission).where(Permission.code == code))
        session.add(RolePermission(role_id=role.id, permission_id=perm.id))
    agent = User(
        id=uuid.uuid4(),
        hotel_id=hotel.id,
        employee_code="RECEP_T",
        first_name="Awa",
        last_name="Traore",
        password_hash=hash_secret("Test1234!"),
        is_active=True,
        must_change_password=False,
    )
    session.add(agent)
    await session.flush()
    session.add(UserRole(user_id=agent.id, role_id=role.id))
    await session.commit()
    return {"Authorization": f"Bearer {await login(client, 'RECEP_T')}"}


async def _client(client, auth) -> str:
    resp = await client.post(
        "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def test_l_administrateur_fixe_le_plafond(client, session, auth_a):
    guest_id = await _client(client, auth_a)

    resp = await client.patch(
        f"/api/v1/guests/{guest_id}",
        json={"first_name": "Awa", "last_name": "Diallo", "credit_limit": 50000},
        headers=auth_a,
    )

    assert resp.status_code == 200, resp.text
    session.expire_all()
    assert (await session.get(Guest, uuid.UUID(guest_id))).credit_limit == 50000


async def test_la_reception_ne_fixe_pas_le_plafond(client, auth_reception):
    guest_id = await _client(client, auth_reception)

    resp = await client.patch(
        f"/api/v1/guests/{guest_id}",
        json={"first_name": "Awa", "last_name": "Diallo", "credit_limit": 50000},
        headers=auth_reception,
    )

    assert resp.status_code == 403


async def test_la_reception_modifie_toujours_la_fiche(client, auth_reception):
    guest_id = await _client(client, auth_reception)

    resp = await client.patch(
        f"/api/v1/guests/{guest_id}",
        json={"first_name": "Awa", "last_name": "Diallo", "phone": "690000000"},
        headers=auth_reception,
    )

    assert resp.status_code == 200, resp.text
