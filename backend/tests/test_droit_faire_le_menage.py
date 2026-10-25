"""Ouvrir un menage n'est pas le faire (migration 0033).

La reception porte `housekeeping.manage` parce que le depart ouvre une tache
de menage. Avec un seul droit, elle pouvait aussi la commencer et la
terminer : une chambre declaree propre sans que personne n'y soit passe.
Commencer, terminer et revenir en arriere passent a `housekeeping.work`, le
geste de la femme de chambre ; ouvrir, attribuer et inspecter restent a
`housekeeping.manage`.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import Permission, Role, RolePermission, Room, RoomType, User, UserRole

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
        first_name="Agent",
        last_name=code,
        password_hash=hash_secret("Test1234!"),
        is_active=True,
        must_change_password=False,
    )
    session.add(agent)
    await session.flush()
    session.add(UserRole(user_id=agent.id, role_id=role.id))
    await session.commit()


@pytest.fixture
async def tache(client, session, hotel_a, login):
    """Une tache ouverte par la reception, et les jetons des deux metiers."""
    hotel, _ = hotel_a
    room_type = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number="101", room_type_id=room_type.id)
    session.add(room)
    await session.commit()

    await _agent(session, hotel, "RECEP_HK", ["housekeeping.read", "housekeeping.manage", "rooms.read"])
    await _agent(
        session,
        hotel,
        "MENAGE_HK",
        ["housekeeping.read", "housekeeping.manage", "housekeeping.work", "rooms.read"],
    )
    reception = {"Authorization": f"Bearer {await login(client, 'RECEP_HK')}"}
    menage = {"Authorization": f"Bearer {await login(client, 'MENAGE_HK')}"}

    task_id = uuid7()
    ouverte = await client.post(
        "/api/v1/housekeeping-tasks",
        json={
            "id": str(task_id),
            "room_id": str(room.id),
            "type": "DEPARTURE",
            "business_date": str(dt.date(2030, 3, 10)),
        },
        headers=reception,
    )
    assert ouverte.status_code == 201, ouverte.text
    return f"/api/v1/housekeeping-tasks/{task_id}", reception, menage


async def test_la_reception_ouvre_mais_ne_commence_pas(client, tache):
    base, reception, _ = tache
    resp = await client.post(f"{base}/start", headers=reception)
    assert resp.status_code == 403, resp.text


async def test_la_reception_ne_termine_ni_ne_corrige(client, tache):
    base, reception, menage = tache
    assert (await client.post(f"{base}/start", headers=menage)).status_code == 200

    fin = await client.post(f"{base}/finish", headers=reception)
    retour = await client.post(
        f"{base}/revert",
        json={"from_status": "IN_PROGRESS", "status": "PENDING"},
        headers=reception,
    )
    assert fin.status_code == 403, fin.text
    assert retour.status_code == 403, retour.text


async def test_la_femme_de_chambre_fait_tout_le_parcours(client, tache):
    base, _, menage = tache
    for geste in ("start", "finish"):
        resp = await client.post(f"{base}/{geste}", headers=menage)
        assert resp.status_code == 200, resp.text
    retour = await client.post(
        f"{base}/revert",
        json={"from_status": "DONE", "status": "IN_PROGRESS"},
        headers=menage,
    )
    assert retour.status_code == 200, retour.text
    assert retour.json()["status"] == "IN_PROGRESS"
