"""Une nuit n'est facturee qu'une fois, meme envoyee par deux tablettes.

Deux tablettes qui ont chacune fait le check-in du meme sejour portent
chacune ses nuits, avec leurs propres identifiants. Le registre des nuits
(`stay_nights`) tranche : la seconde nuitee recoit la premiere en reponse,
sans nouvelle charge.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.models import Folio, FolioItem, Room, RoomType, StayNight

pytestmark = pytest.mark.db

NUIT = dt.date(2030, 3, 10)


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def ardoise(client, session, hotel_a, auth_a):
    """Un sejour d'une nuit, arrive ; renvoie l'ardoise et la ligne."""
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
    resp = await client.post(
        "/api/v1/reservations",
        json={
            "id": res_id,
            "guest_id": guest["id"],
            "rooms": [
                {
                    "id": line_id,
                    "room_type_id": str(room_type.id),
                    "arrival_date": str(NUIT),
                    "departure_date": str(NUIT + dt.timedelta(days=1)),
                }
            ],
        },
        headers=auth_a,
    )
    assert resp.status_code in (200, 201), resp.text
    resp = await client.post(
        f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in",
        json={"room_id": str(room.id), "folio_id": folio_id},
        headers=auth_a,
    )
    assert resp.status_code == 200, resp.text
    return folio_id, line_id


def _nuitee(**extra) -> dict:
    return {
        "id": str(uuid7()),
        "category": "ROOM",
        "label": "Nuitee du 10 mars",
        "unit_price": 25_000,
        "night_date": str(NUIT),
        **extra,
    }


async def test_la_meme_nuit_envoyee_deux_fois_n_est_comptee_qu_une_fois(
    client, session, auth_a, ardoise
):
    folio_id, _ = ardoise
    url = f"/api/v1/folios/{folio_id}/items"

    premiere = await client.post(url, json=_nuitee(), headers=auth_a)
    seconde = await client.post(url, json=_nuitee(), headers=auth_a)

    assert premiere.status_code == 201, premiere.text
    assert seconde.status_code == 200, seconde.text
    assert seconde.json()["id"] == premiere.json()["id"]

    session.expire_all()
    folio = await session.get(Folio, uuid.UUID(folio_id))
    assert folio.charges_total == 25_000


async def test_la_nuitee_est_rattachee_au_registre_et_datee_de_sa_nuit(
    client, session, auth_a, ardoise
):
    folio_id, line_id = ardoise

    resp = await client.post(f"/api/v1/folios/{folio_id}/items", json=_nuitee(), headers=auth_a)

    session.expire_all()
    item = await session.get(FolioItem, uuid.UUID(resp.json()["id"]))
    night = await session.scalar(
        select(StayNight).where(StayNight.reservation_room_id == uuid.UUID(line_id))
    )
    assert item.business_date == NUIT
    assert item.source_table == "stay_nights"
    assert item.source_id == night.id
    assert night.is_posted


async def test_une_charge_ordinaire_n_est_pas_dedoublonnee(client, session, auth_a, ardoise):
    folio_id, _ = ardoise
    url = f"/api/v1/folios/{folio_id}/items"
    cafe = {"category": "FNB", "label": "Cafe", "unit_price": 1_500}

    await client.post(url, json={**cafe, "id": str(uuid7())}, headers=auth_a)
    await client.post(url, json={**cafe, "id": str(uuid7())}, headers=auth_a)

    session.expire_all()
    assert (await session.get(Folio, uuid.UUID(folio_id))).charges_total == 3_000
