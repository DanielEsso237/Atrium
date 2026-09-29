"""Le check-in dit a la tablette quelle ardoise il a retenue.

Un sejour deja arrive qui recoit le check-in d'une autre tablette garde son
ardoise : le serveur ignore celle qu'on lui propose. Il doit alors la
designer dans sa reponse, pour que la tablette l'adopte -- sinon tout ce
qu'elle porte sur la sienne repond 404 et bloque sa file.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import func, select

from app.core.ids import uuid7
from app.models import Folio, Room, RoomType

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def room_a(session, hotel_a):
    hotel, _ = hotel_a
    room_type = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number="101", room_type_id=room_type.id)
    session.add(room)
    await session.commit()
    return room_type.id, room.id


async def _reserver(client, auth, room_type_id) -> tuple[str, str]:
    guest = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth
        )
    ).json()
    res_id, line_id = str(uuid7()), str(uuid7())
    resp = await client.post(
        "/api/v1/reservations",
        json={
            "id": res_id,
            "guest_id": guest["id"],
            "rooms": [
                {
                    "id": line_id,
                    "room_type_id": str(room_type_id),
                    "arrival_date": str(dt.date(2030, 3, 10)),
                    "departure_date": str(dt.date(2030, 3, 11)),
                }
            ],
        },
        headers=auth,
    )
    assert resp.status_code in (200, 201), resp.text
    return res_id, line_id


async def test_le_check_in_renvoie_l_ardoise_de_la_tablette(client, auth_a, room_a):
    room_type_id, room_id = room_a
    res_id, line_id = await _reserver(client, auth_a, room_type_id)
    folio_id = str(uuid7())

    resp = await client.post(
        f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in",
        json={"room_id": str(room_id), "folio_id": folio_id},
        headers=auth_a,
    )

    assert resp.status_code == 200, resp.text
    assert resp.json()["folio_id"] == folio_id


async def test_un_check_in_rejoue_designe_l_ardoise_du_serveur(
    client, session, auth_a, room_a
):
    room_type_id, room_id = room_a
    res_id, line_id = await _reserver(client, auth_a, room_type_id)
    url = f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in"
    premiere = str(uuid7())
    await client.post(url, json={"room_id": str(room_id), "folio_id": premiere}, headers=auth_a)

    # Une autre tablette, qui croyait le sejour a venir, propose la sienne.
    resp = await client.post(
        url, json={"room_id": str(room_id), "folio_id": str(uuid7())}, headers=auth_a
    )

    assert resp.status_code == 200, resp.text
    assert resp.json()["folio_id"] == premiere
    nombre = await session.scalar(
        select(func.count())
        .select_from(Folio)
        .where(Folio.reservation_room_id == uuid.UUID(line_id))
    )
    assert nombre == 1
