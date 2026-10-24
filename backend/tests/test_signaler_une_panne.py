"""La reception signale une panne ; le technicien la traite.

Retour du 23 octobre : « donner la possibilite de signaler une maintenance
a la reception ». `maintenance.report` ouvre un ticket et rien d'autre.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

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


async def _chambre(session, hotel) -> Room:
    categorie = RoomType(hotel_id=hotel.id, code="SIG", label="Standard", default_rate=25_000)
    session.add(categorie)
    await session.flush()
    chambre = Room(hotel_id=hotel.id, number="901", room_type_id=categorie.id)
    session.add(chambre)
    await session.commit()
    return chambre


async def _entete(client, login, code) -> dict:
    return {"Authorization": f"Bearer {await login(client, code)}"}


@pytest.fixture
async def reception(client, session, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(
        session, hotel, "RECEP_SIG", ["maintenance.report", "maintenance.read", "rooms.read"]
    )
    return await _entete(client, login, "RECEP_SIG")


async def test_la_reception_ouvre_un_ticket(client, session, hotel_a, reception):
    hotel, _ = hotel_a
    chambre = await _chambre(session, hotel)

    r = await client.post(
        "/api/v1/maintenance-tickets",
        json={
            "room_id": str(chambre.id),
            "title": "La climatisation ne marche plus",
            "priority": "HIGH",
            "blocks_room": True,
        },
        headers=reception,
    )
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "OPEN"
    # Un ticket bloquant sort la chambre de la vente, qui que l'ouvre.
    await session.refresh(chambre)
    assert chambre.is_out_of_order is True

    # Elle suit ce qu'elle a signale.
    liste = await client.get("/api/v1/maintenance-tickets", headers=reception)
    assert liste.status_code == 200
    assert [t["title"] for t in liste.json()] == ["La climatisation ne marche plus"]


async def test_la_reception_ne_traite_pas_le_ticket(
    client, session, hotel_a, reception, login
):
    hotel, admin = hotel_a
    chambre = await _chambre(session, hotel)
    r = await client.post(
        "/api/v1/maintenance-tickets",
        json={"room_id": str(chambre.id), "title": "Fuite", "blocks_room": False},
        headers=reception,
    )
    ticket = r.json()["id"]

    for verbe, corps in [
        ("assign", {"user_id": str(admin.id)}),
        ("resolve", {}),
        ("close", {}),
    ]:
        refus = await client.post(
            f"/api/v1/maintenance-tickets/{ticket}/{verbe}", json=corps, headers=reception
        )
        assert refus.status_code == 403, f"{verbe} : {refus.text}"


async def test_sans_aucun_droit_de_maintenance_rien_ne_s_ouvre(
    client, session, hotel_a, login
):
    hotel, _ = hotel_a
    await _agent(session, hotel, "BAR_SIG", ["order.read"])
    r = await client.post(
        "/api/v1/maintenance-tickets",
        json={"title": "Ampoule grillee"},
        headers=await _entete(client, login, "BAR_SIG"),
    )
    assert r.status_code == 403
