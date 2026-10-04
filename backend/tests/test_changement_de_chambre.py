"""Changer de chambre un client deja arrive.

L'ancienne chambre redevient vacante **sans** devenir sale : le client n'y a
pas dormi. C'est l'inverse du depart, qui la rend a nettoyer. Le folio est
rattache a la ligne, il suit le client sans qu'on y touche.

Seuls les conflits physiques sont refuses ; une chambre sale ne l'est pas,
pour ne pas bloquer la file d'une tablette dont l'etat de menage est en
retard. Un renvoi repond 200.
"""

from __future__ import annotations

import datetime as dt

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.models import Folio, ReservationRoom, Room, RoomType
from app.models.enums import HousekeepingStatus, OccupancyStatus

pytestmark = pytest.mark.db

ARRIVAL = dt.date(2030, 3, 10)
DEPARTURE = dt.date(2030, 3, 12)


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def rooms_a(session, hotel_a):
    """Trois standards et une suite, toutes propres et libres."""
    hotel, _ = hotel_a
    standard = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    suite = RoomType(hotel_id=hotel.id, code="STE", label="Suite", default_rate=60_000)
    session.add_all([standard, suite])
    await session.flush()
    rooms = [
        Room(hotel_id=hotel.id, number=n, room_type_id=standard.id) for n in ("101", "102", "103")
    ]
    rooms.append(Room(hotel_id=hotel.id, number="501", room_type_id=suite.id))
    session.add_all(rooms)
    await session.commit()
    return standard, rooms


async def _arrive(client, auth, room_type, room) -> tuple[str, str, str]:
    """Reserve et fait arriver un client ; renvoie dossier, ligne et folio."""
    guest = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth
        )
    ).json()
    res_id, line_id, folio_id = str(uuid7()), str(uuid7()), str(uuid7())
    resp = await client.post(
        "/api/v1/reservations",
        json={
            "id": res_id,
            "guest_id": guest["id"],
            "rooms": [
                {
                    "id": line_id,
                    "room_type_id": str(room_type.id),
                    "arrival_date": str(ARRIVAL),
                    "departure_date": str(DEPARTURE),
                }
            ],
        },
        headers=auth,
    )
    assert resp.status_code in (200, 201), resp.text
    resp = await client.post(
        f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in",
        json={"room_id": str(room.id), "folio_id": folio_id},
        headers=auth,
    )
    assert resp.status_code == 200, resp.text
    return res_id, line_id, folio_id


def _url(res_id, line_id) -> str:
    return f"/api/v1/reservations/{res_id}/rooms/{line_id}/change-room"


async def _room(session, room_id) -> Room:
    # L'identifiant et non l'objet : `expire_all` expire aussi les chambres du
    # montage, et relire leur `id` declencherait une lecture synchrone.
    session.expire_all()
    return await session.get(Room, room_id)


async def test_l_ancienne_redevient_libre_et_reste_propre(client, session, auth_a, rooms_a):
    standard, (r101, r102, *_) = rooms_a
    id101, id102 = r101.id, r102.id
    res_id, line_id, _ = await _arrive(client, auth_a, standard, r101)

    resp = await client.post(_url(res_id, line_id), json={"room_id": str(id102)}, headers=auth_a)

    assert resp.status_code == 200, resp.text
    ancienne = await _room(session, id101)
    assert ancienne.occupancy_status == OccupancyStatus.VACANT
    assert ancienne.housekeeping_status == HousekeepingStatus.CLEAN
    assert (await _room(session, id102)).occupancy_status == OccupancyStatus.OCCUPIED


async def test_l_ardoise_suit_le_client(client, session, auth_a, rooms_a):
    standard, (r101, r102, *_) = rooms_a
    id102 = r102.id
    res_id, line_id, folio_id = await _arrive(client, auth_a, standard, r101)

    await client.post(_url(res_id, line_id), json={"room_id": str(id102)}, headers=auth_a)

    session.expire_all()
    line = await session.get(ReservationRoom, line_id)
    assert line.room_id == id102
    folio = await session.scalar(select(Folio).where(Folio.reservation_room_id == line.id))
    assert str(folio.id) == folio_id


async def test_renvoi_repond_200(client, auth_a, rooms_a):
    standard, (r101, r102, *_) = rooms_a
    res_id, line_id, _ = await _arrive(client, auth_a, standard, r101)
    body = {"room_id": str(r102.id)}

    first = await client.post(_url(res_id, line_id), json=body, headers=auth_a)
    again = await client.post(_url(res_id, line_id), json=body, headers=auth_a)

    assert first.status_code == again.status_code == 200


async def test_une_chambre_sale_n_est_pas_refusee(client, session, auth_a, rooms_a):
    standard, (r101, r102, *_) = rooms_a
    id102 = r102.id
    res_id, line_id, _ = await _arrive(client, auth_a, standard, r101)
    (await _room(session, id102)).housekeeping_status = HousekeepingStatus.DIRTY
    await session.commit()

    resp = await client.post(_url(res_id, line_id), json={"room_id": str(id102)}, headers=auth_a)

    assert resp.status_code == 200, resp.text


async def test_autre_categorie_refusee(client, auth_a, rooms_a):
    standard, (r101, *_, suite) = rooms_a
    res_id, line_id, _ = await _arrive(client, auth_a, standard, r101)

    resp = await client.post(_url(res_id, line_id), json={"room_id": str(suite.id)}, headers=auth_a)

    assert resp.status_code == 422


async def test_chambre_occupee_refusee(client, auth_a, rooms_a):
    standard, (r101, r102, *_) = rooms_a
    res_id, line_id, _ = await _arrive(client, auth_a, standard, r101)
    await _arrive(client, auth_a, standard, r102)

    resp = await client.post(_url(res_id, line_id), json={"room_id": str(r102.id)}, headers=auth_a)

    assert resp.status_code == 409


async def test_avant_l_arrivee_refuse(client, auth_a, rooms_a):
    standard, (r101, r102, *_) = rooms_a
    guest = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth_a
        )
    ).json()
    res_id, line_id = str(uuid7()), str(uuid7())
    await client.post(
        "/api/v1/reservations",
        json={
            "id": res_id,
            "guest_id": guest["id"],
            "rooms": [
                {
                    "id": line_id,
                    "room_type_id": str(standard.id),
                    "arrival_date": str(ARRIVAL),
                    "departure_date": str(DEPARTURE),
                }
            ],
        },
        headers=auth_a,
    )

    resp = await client.post(_url(res_id, line_id), json={"room_id": str(r102.id)}, headers=auth_a)

    assert resp.status_code == 409
