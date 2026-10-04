"""Le comptoir porte sur l'ardoise, il n'encaisse pas.

`folio.charge` suffit pour porter une consommation sur une chambre ; il ne
permet ni d'encaisser ni de clore une ardoise, qui restent a folio.write.
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


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def auth_comptoir(client, session, hotel_a, login):
    """Un agent du comptoir : il porte, il n'encaisse pas."""
    hotel, _ = hotel_a
    perm = await session.scalar(select(Permission).where(Permission.code == "folio.charge"))
    if perm is None:
        perm = Permission(id=uuid.uuid4(), code="folio.charge", label="charge", module="folio")
        session.add(perm)
    role = Role(id=uuid.uuid4(), code="COMPTOIR_TEST", label="Comptoir")
    session.add(role)
    await session.flush()
    session.add(RolePermission(role_id=role.id, permission_id=perm.id))
    agent = User(
        id=uuid.uuid4(),
        hotel_id=hotel.id,
        employee_code="BT_T",
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
    return {"Authorization": f"Bearer {await login(client, 'BT_T')}"}


@pytest.fixture
async def ardoise(client, session, hotel_a, auth_a):
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


async def test_le_comptoir_porte_une_consommation(client, auth_comptoir, ardoise):
    resp = await client.post(
        f"/api/v1/folios/{ardoise}/items",
        json={"id": str(uuid7()), "category": "FNB", "label": "Eau", "unit_price": 400},
        headers=auth_comptoir,
    )

    assert resp.status_code == 201, resp.text


async def test_le_comptoir_n_encaisse_pas(client, auth_comptoir, ardoise):
    resp = await client.post(
        f"/api/v1/folios/{ardoise}/payments",
        json={"id": str(uuid7()), "method": "CASH", "amount": 400},
        headers=auth_comptoir,
    )

    assert resp.status_code == 403
