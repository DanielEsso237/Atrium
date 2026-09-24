"""Ecritures rejouables avec les ids de la tablette (carte « Accepter les

identifiants de la tablette »).

Une tablette qui perd le reseau apres l'envoi ne sait pas si l'ecriture est
passee et la renvoie telle quelle, meme id. Chaque test verifie les deux
promesses : aucun doublon, et jamais de 409 sur un rejeu (il bloquerait la
file d'envoi de la tablette). Un id d'un autre hotel repond 404.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import func, select

from app.core.ids import uuid7
from app.models import Folio, FolioItem, Guest, Payment, Reservation, ReservationRoom, Room, RoomType

pytestmark = pytest.mark.db

ARRIVAL = dt.date(2030, 3, 10)
DEPARTURE = dt.date(2030, 3, 12)


async def _room(session, hotel) -> tuple[RoomType, Room]:
    """Un type a UNE chambre : la premiere reservation remplit l'hotel."""
    room_type = RoomType(
        hotel_id=hotel.id, code=f"T{hotel.code}", label="Standard", default_rate=25_000
    )
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number=f"1{hotel.code}", room_type_id=room_type.id)
    session.add(room)
    await session.commit()
    return room_type, room


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def auth_b(client, hotel_b, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_B')}"}


async def _count(session, model, **where) -> int:
    stmt = select(func.count()).select_from(model)
    for column, value in where.items():
        stmt = stmt.where(getattr(model, column) == value)
    return await session.scalar(stmt)


async def _guest(client, auth, **extra) -> dict:
    resp = await client.post(
        "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo", **extra}, headers=auth
    )
    assert resp.status_code in (200, 201), resp.text
    return resp.json()


def _reservation_body(guest_id, room_type_id, reservation_id=None, line_id=None) -> dict:
    line = {
        "room_type_id": str(room_type_id),
        "arrival_date": str(ARRIVAL),
        "departure_date": str(DEPARTURE),
    }
    body = {"guest_id": guest_id, "rooms": [line]}
    if reservation_id:
        body["id"] = str(reservation_id)
    if line_id:
        line["id"] = str(line_id)
    return body


# --- Clients ---------------------------------------------------------------------


async def test_deux_post_guests_meme_id_une_seule_ligne(client, session, auth_a):
    guest_id = uuid7()
    first = await client.post(
        "/api/v1/guests",
        json={"id": str(guest_id), "first_name": "Awa", "last_name": "Diallo"},
        headers=auth_a,
    )
    again = await client.post(
        "/api/v1/guests",
        json={"id": str(guest_id), "first_name": "Awa", "last_name": "Diallo-Kone"},
        headers=auth_a,
    )
    assert first.status_code == 201, first.text
    assert again.status_code == 200, again.text
    assert first.json()["id"] == again.json()["id"] == str(guest_id)
    assert again.json()["last_name"] == "Diallo-Kone"  # le renvoi met a jour
    assert again.json()["code"] == first.json()["code"]  # sans nouveau numero
    assert await _count(session, Guest, id=guest_id) == 1


async def test_post_guest_sans_id_se_comporte_comme_avant(client, auth_a):
    a = await _guest(client, auth_a)
    b = await _guest(client, auth_a)
    assert a["id"] != b["id"] and a["code"] != b["code"]


async def test_guest_id_d_un_autre_hotel_404_sans_rien_ecraser(client, session, auth_a, auth_b):
    theirs = await _guest(client, auth_b)
    resp = await client.post(
        "/api/v1/guests",
        json={"id": theirs["id"], "first_name": "Pirate", "last_name": "X"},
        headers=auth_a,
    )
    assert resp.status_code == 404
    session.expire_all()
    guest = await session.get(Guest, uuid.UUID(theirs["id"]))
    assert guest.first_name == "Awa"


# --- Reservations --------------------------------------------------------------------


async def test_reservation_ids_imposes_conserves_et_rejeu_sans_409(
    client, session, hotel_a, auth_a
):
    hotel, _ = hotel_a
    room_type, _ = await _room(session, hotel)
    guest = await _guest(client, auth_a)
    reservation_id, line_id = uuid7(), uuid7()
    body = _reservation_body(guest["id"], room_type.id, reservation_id, line_id)

    first = await client.post("/api/v1/reservations", json=body, headers=auth_a)
    assert first.status_code == 201, first.text
    assert first.json()["id"] == str(reservation_id)
    assert first.json()["rooms"][0]["id"] == str(line_id)

    # L'hotel est desormais complet sur ces dates : le rejeu doit malgre tout
    # repondre 200, pas 409 "plus de disponibilite".
    again = await client.post("/api/v1/reservations", json=body, headers=auth_a)
    assert again.status_code == 200, again.text
    assert again.json()["reference"] == first.json()["reference"]
    assert await _count(session, Reservation, id=reservation_id) == 1
    assert await _count(session, ReservationRoom, reservation_id=reservation_id) == 1

    # Un autre dossier sur les memes dates, lui, est bien refuse.
    other = _reservation_body(guest["id"], room_type.id)
    assert (await client.post("/api/v1/reservations", json=other, headers=auth_a)).status_code == 409


async def test_reservation_id_d_un_autre_hotel_404(client, session, hotel_a, hotel_b, auth_a, auth_b):
    type_a, _ = await _room(session, hotel_a[0])
    type_b, _ = await _room(session, hotel_b[0])
    theirs = await client.post(
        "/api/v1/reservations",
        json=_reservation_body((await _guest(client, auth_b))["id"], type_b.id, uuid7()),
        headers=auth_b,
    )
    assert theirs.status_code == 201, theirs.text
    body = _reservation_body((await _guest(client, auth_a))["id"], type_a.id, theirs.json()["id"])
    assert (await client.post("/api/v1/reservations", json=body, headers=auth_a)).status_code == 404


async def test_check_in_check_out_et_annulation_rejouables(client, session, hotel_a, auth_a):
    room_type, room = await _room(session, hotel_a[0])
    guest = await _guest(client, auth_a)
    res = (
        await client.post(
            "/api/v1/reservations",
            json=_reservation_body(guest["id"], room_type.id),
            headers=auth_a,
        )
    ).json()
    line_id = res["rooms"][0]["id"]
    base = f"/api/v1/reservations/{res['id']}/rooms/{line_id}"
    folio_id = uuid7()

    check_in = {"room_id": str(room.id), "folio_id": str(folio_id)}
    first = await client.post(f"{base}/check-in", json=check_in, headers=auth_a)
    again = await client.post(f"{base}/check-in", json=check_in, headers=auth_a)
    assert first.status_code == 200, first.text
    assert again.status_code == 200, again.text
    assert again.json()["rooms"][0]["status"] == "CHECKED_IN"
    folios = (
        await session.execute(select(Folio.id).where(Folio.reservation_room_id == uuid.UUID(line_id)))
    ).scalars().all()
    assert folios == [folio_id]  # un seul folio, avec l'id de la tablette

    assert (await client.post(f"{base}/check-out", headers=auth_a)).status_code == 200
    again = await client.post(f"{base}/check-out", headers=auth_a)
    assert again.status_code == 200, again.text
    assert again.json()["status"] == "CHECKED_OUT"

    # Annulation rejouee, sur un autre dossier (celui-ci est parti).
    other = (
        await client.post(
            "/api/v1/reservations",
            json={**_reservation_body(guest["id"], room_type.id), "rooms": [{
                "room_type_id": str(room_type.id),
                "arrival_date": "2030-06-01",
                "departure_date": "2030-06-02",
            }]},
            headers=auth_a,
        )
    ).json()
    url = f"/api/v1/reservations/{other['id']}/cancel"
    first = await client.post(url, json={"reason": "Vol annule"}, headers=auth_a)
    again = await client.post(url, json={"reason": "rejeu"}, headers=auth_a)
    assert first.status_code == again.status_code == 200
    assert again.json()["cancel_reason"] == "Vol annule"  # le rejeu ne reecrit rien


# --- Charges et paiements ------------------------------------------------------------


async def _open_folio(client, session, hotel, auth) -> str:
    room_type, room = await _room(session, hotel)
    guest = await _guest(client, auth)
    res = (
        await client.post(
            "/api/v1/reservations", json=_reservation_body(guest["id"], room_type.id), headers=auth
        )
    ).json()
    folio_id = uuid7()
    resp = await client.post(
        f"/api/v1/reservations/{res['id']}/rooms/{res['rooms'][0]['id']}/check-in",
        json={"room_id": str(room.id), "folio_id": str(folio_id)},
        headers=auth,
    )
    assert resp.status_code == 200, resp.text
    return str(folio_id)


async def test_charge_et_paiement_rejoues_comptes_une_fois(client, session, hotel_a, auth_a):
    folio_id = await _open_folio(client, session, hotel_a[0], auth_a)
    item = {"id": str(uuid7()), "category": "MINIBAR", "label": "Coca", "unit_price": 1000}
    first = await client.post(f"/api/v1/folios/{folio_id}/items", json=item, headers=auth_a)
    again = await client.post(f"/api/v1/folios/{folio_id}/items", json=item, headers=auth_a)
    assert (first.status_code, again.status_code) == (201, 200), again.text
    assert first.json()["id"] == again.json()["id"] == item["id"]
    assert await _count(session, FolioItem, folio_id=uuid.UUID(folio_id)) == 1

    payment = {"id": str(uuid7()), "method": "CASH", "amount": 1000}
    first = await client.post(f"/api/v1/folios/{folio_id}/payments", json=payment, headers=auth_a)
    again = await client.post(f"/api/v1/folios/{folio_id}/payments", json=payment, headers=auth_a)
    assert (first.status_code, again.status_code) == (201, 200), again.text
    assert again.json()["payments_total"] == 1000 and again.json()["balance"] == 0
    assert await _count(session, Payment, folio_id=uuid.UUID(folio_id)) == 1

    # Folio clos entre-temps : les rejeux repondent toujours 200, pas 409.
    assert (await client.post(f"/api/v1/folios/{folio_id}/close", headers=auth_a)).status_code == 200
    for url, body in (("items", item), ("payments", payment)):
        resp = await client.post(f"/api/v1/folios/{folio_id}/{url}", json=body, headers=auth_a)
        assert resp.status_code == 200, (url, resp.text)


async def test_charge_d_un_autre_hotel_404(client, session, hotel_a, hotel_b, auth_a, auth_b):
    folio_a = await _open_folio(client, session, hotel_a[0], auth_a)
    folio_b = await _open_folio(client, session, hotel_b[0], auth_b)
    item = {"id": str(uuid7()), "category": "MINIBAR", "label": "Coca", "unit_price": 1000}
    assert (
        await client.post(f"/api/v1/folios/{folio_b}/items", json=item, headers=auth_b)
    ).status_code == 201
    resp = await client.post(f"/api/v1/folios/{folio_a}/items", json=item, headers=auth_a)
    assert resp.status_code == 404
