"""Facture et caisse : renvoyer ne doit rien creer en double.

Ni l'une ni l'autre n'accepte d'identifiant de la tablette, contrairement aux
clients ou aux ardoises. Ce n'est pas un manque : les deux ont une **cle
naturelle**. Une ardoise n'a qu'une facture, un agent n'a qu'une caisse
ouverte. C'est cette regle metier, et non un identifiant invente, qui rend le
renvoi sans danger.

Ce qu'on evite ici se compte en argent : une seconde facture porterait un
second numero legal pour les memes prestations, et une seconde caisse
couperait la journee d'un agent en deux comptages qui ne tomberont jamais
justes.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import func, select

from app.core.ids import uuid7
from app.models import CashSession, Invoice, Room, RoomType

pytestmark = pytest.mark.db

ARRIVAL = dt.date(2030, 3, 10)
DEPARTURE = dt.date(2030, 3, 12)


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def _folio_avec_charge(client, session, hotel, auth, montant: int = 50_000) -> str:
    room_type = RoomType(
        hotel_id=hotel.id, code=f"T{hotel.code}", label="Standard", default_rate=25_000
    )
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number=f"1{hotel.code}", room_type_id=room_type.id)
    session.add(room)
    await session.commit()

    guest = (
        await client.post(
            "/api/v1/guests",
            json={"first_name": "Awa", "last_name": "Diallo"},
            headers=auth,
        )
    ).json()
    res = (
        await client.post(
            "/api/v1/reservations",
            json={
                "guest_id": guest["id"],
                "rooms": [
                    {
                        "room_type_id": str(room_type.id),
                        "arrival_date": str(ARRIVAL),
                        "departure_date": str(DEPARTURE),
                    }
                ],
            },
            headers=auth,
        )
    ).json()

    folio_id = uuid7()
    resp = await client.post(
        f"/api/v1/reservations/{res['id']}/rooms/{res['rooms'][0]['id']}/check-in",
        json={"room_id": str(room.id), "folio_id": str(folio_id)},
        headers=auth,
    )
    assert resp.status_code == 200, resp.text

    charge = await client.post(
        f"/api/v1/folios/{folio_id}/items",
        json={"category": "ROOM", "label": "Nuitee", "unit_price": montant},
        headers=auth,
    )
    assert charge.status_code == 201, charge.text
    return str(folio_id)


# --- La facture ------------------------------------------------------------


async def test_reemettre_rend_la_meme_facture(client, session, hotel_a, auth_a):
    folio = await _folio_avec_charge(client, session, hotel_a[0], auth_a)

    premiere = await client.post(f"/api/v1/folios/{folio}/invoice", headers=auth_a)
    rejeu = await client.post(f"/api/v1/folios/{folio}/invoice", headers=auth_a)

    assert premiere.status_code == 201, premiere.text
    assert rejeu.status_code == 200, rejeu.text

    # Le meme numero legal, surtout : deux numeros pour les memes prestations
    # est une faute comptable, pas une simple duplication.
    assert premiere.json()["number"] == rejeu.json()["number"]
    assert premiere.json()["id"] == rejeu.json()["id"]

    combien = await session.scalar(
        select(func.count())
        .select_from(Invoice)
        .where(Invoice.folio_id == uuid.UUID(folio))
    )
    assert combien == 1


async def test_un_folio_sans_charge_ne_se_facture_pas(client, session, hotel_a, auth_a):
    """Le controle existant ne doit pas tomber avec le court-circuit."""
    room_type = RoomType(
        hotel_id=hotel_a[0].id, code="TVIDE", label="Standard", default_rate=25_000
    )
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel_a[0].id, number="199", room_type_id=room_type.id)
    session.add(room)
    await session.commit()

    guest = (
        await client.post(
            "/api/v1/guests",
            json={"first_name": "Sans", "last_name": "Charge"},
            headers=auth_a,
        )
    ).json()
    res = (
        await client.post(
            "/api/v1/reservations",
            json={
                "guest_id": guest["id"],
                "rooms": [
                    {
                        "room_type_id": str(room_type.id),
                        "arrival_date": str(ARRIVAL),
                        "departure_date": str(DEPARTURE),
                    }
                ],
            },
            headers=auth_a,
        )
    ).json()
    folio_id = uuid7()
    await client.post(
        f"/api/v1/reservations/{res['id']}/rooms/{res['rooms'][0]['id']}/check-in",
        json={"room_id": str(room.id), "folio_id": str(folio_id)},
        headers=auth_a,
    )

    resp = await client.post(f"/api/v1/folios/{folio_id}/invoice", headers=auth_a)
    assert resp.status_code == 422, resp.text


# --- La caisse -------------------------------------------------------------


async def test_rouvrir_rend_la_caisse_deja_ouverte(client, session, hotel_a, auth_a):
    premiere = await client.post(
        "/api/v1/cash-sessions", json={"opening_float": 20_000}, headers=auth_a
    )
    rejeu = await client.post(
        "/api/v1/cash-sessions", json={"opening_float": 20_000}, headers=auth_a
    )

    assert premiere.status_code == 201, premiere.text
    # Sans ce 200, un renvoi de la tablette recevait 409 et bloquait sa file
    # d'envoi -- avec tous les encaissements de la journee derriere.
    assert rejeu.status_code == 200, rejeu.text
    assert premiere.json()["id"] == rejeu.json()["id"]

    combien = await session.scalar(select(func.count()).select_from(CashSession))
    assert combien == 1


async def test_le_premier_fond_de_caisse_fait_foi(client, session, hotel_a, auth_a):
    """Un renvoi ne doit pas pouvoir reecrire le comptage d'ouverture."""
    await client.post(
        "/api/v1/cash-sessions", json={"opening_float": 20_000}, headers=auth_a
    )
    rejeu = await client.post(
        "/api/v1/cash-sessions", json={"opening_float": 99_000}, headers=auth_a
    )

    assert rejeu.status_code == 200
    assert rejeu.json()["opening_float"] == 20_000


async def test_apres_fermeture_on_peut_rouvrir(client, session, hotel_a, auth_a):
    """Le court-circuit ne doit pas enfermer l'agent dans sa session.

    La releve suivante ouvre bien une caisse neuve.
    """
    premiere = (
        await client.post(
            "/api/v1/cash-sessions", json={"opening_float": 20_000}, headers=auth_a
        )
    ).json()

    ferme = await client.post(
        f"/api/v1/cash-sessions/{premiere['id']}/close",
        json={"counted_amount": 20_000},
        headers=auth_a,
    )
    assert ferme.status_code == 200, ferme.text

    seconde = await client.post(
        "/api/v1/cash-sessions", json={"opening_float": 30_000}, headers=auth_a
    )
    assert seconde.status_code == 201, seconde.text
    assert seconde.json()["id"] != premiere["id"]
