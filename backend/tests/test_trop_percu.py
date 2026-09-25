"""On n'encaisse pas plus que ce qui reste du.

Constate a l'usage sur la tablette : la meme facture pouvait etre encaissee
deux fois. Rien ne plantait -- le solde passait en negatif, et l'ecart
n'apparaissait qu'a la fermeture de caisse, sans qu'on sache de quel client il
venait.

Le garde-fou pose sur la tablette ne suffit pas : c'est le serveur qui fait
foi, et il acceptait le trop-percu.

Le test qui compte le plus ici est le dernier : un paiement **rejoue** doit
toujours repondre 200, meme quand il a solde le folio. Le refuser bloquerait
la file d'envoi de la tablette et tout ce qui attend derriere.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import func, select

from app.core.ids import uuid7
from app.models import Payment, Room, RoomType

pytestmark = pytest.mark.db

ARRIVAL = dt.date(2030, 3, 10)
DEPARTURE = dt.date(2030, 3, 12)


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def _folio_avec_note(client, session, hotel, auth, montant: int) -> str:
    """Un folio ouvert portant une seule charge de `montant`."""
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

    # `/items` renvoie la ligne creee, pas le folio : le solde se lit sur le
    # folio. On le verifie ici pour que les tests qui suivent partent d'un
    # etat connu -- sans quoi un echec de solde se lirait comme un echec du
    # garde-fou.
    etat = await client.get(f"/api/v1/folios/{folio_id}", headers=auth)
    assert etat.status_code == 200, etat.text
    assert etat.json()["balance"] == montant, etat.text
    return str(folio_id)


async def _paiements(session, folio_id: str) -> int:
    return await session.scalar(
        select(func.count())
        .select_from(Payment)
        .where(Payment.folio_id == uuid.UUID(folio_id))
    )


async def test_encaisser_plus_que_le_reste_du_est_refuse(client, session, hotel_a, auth_a):
    folio = await _folio_avec_note(client, session, hotel_a[0], auth_a, 50_000)

    resp = await client.post(
        f"/api/v1/folios/{folio}/payments",
        json={"method": "CASH", "amount": 60_000},
        headers=auth_a,
    )

    assert resp.status_code == 409, resp.text
    assert await _paiements(session, folio) == 0, "un refus ne doit rien ecrire"


async def test_encaisser_deux_fois_la_meme_facture_est_refuse(client, session, hotel_a, auth_a):
    folio = await _folio_avec_note(client, session, hotel_a[0], auth_a, 50_000)
    solde = {"method": "CASH", "amount": 50_000}

    premier = await client.post(
        f"/api/v1/folios/{folio}/payments", json=solde, headers=auth_a
    )
    assert premier.status_code == 201, premier.text
    assert premier.json()["balance"] == 0

    # Deuxieme paiement, id different : ce n'est pas un rejeu, c'est bien un
    # second encaissement. Il n'a plus rien a encaisser.
    second = await client.post(
        f"/api/v1/folios/{folio}/payments", json=solde, headers=auth_a
    )
    assert second.status_code == 409, second.text
    assert await _paiements(session, folio) == 1


async def test_les_paiements_partiels_restent_possibles(client, session, hotel_a, auth_a):
    """Le cas legitime : le client paie en deux fois, au comptoir."""
    folio = await _folio_avec_note(client, session, hotel_a[0], auth_a, 50_000)

    a = await client.post(
        f"/api/v1/folios/{folio}/payments",
        json={"method": "CASH", "amount": 30_000},
        headers=auth_a,
    )
    assert a.status_code == 201 and a.json()["balance"] == 20_000

    b = await client.post(
        f"/api/v1/folios/{folio}/payments",
        json={"method": "MOBILE_MONEY", "amount": 20_000},
        headers=auth_a,
    )
    assert b.status_code == 201 and b.json()["balance"] == 0
    assert await _paiements(session, folio) == 2


async def test_un_paiement_rejoue_repond_toujours_200(client, session, hotel_a, auth_a):
    """Le garde-fou ne doit pas se declencher sur un rejeu.

    La tablette qui perd la reponse renvoie le meme paiement, avec le meme id.
    A ce moment le folio est deja solde : si le serveur repondait 409, la file
    d'envoi se bloquerait sur une ecriture pourtant deja passee, et tout ce qui
    attend derriere avec elle.
    """
    folio = await _folio_avec_note(client, session, hotel_a[0], auth_a, 50_000)
    paiement = {"id": str(uuid7()), "method": "CASH", "amount": 50_000}

    premier = await client.post(
        f"/api/v1/folios/{folio}/payments", json=paiement, headers=auth_a
    )
    rejeu = await client.post(
        f"/api/v1/folios/{folio}/payments", json=paiement, headers=auth_a
    )

    assert premier.status_code == 201, premier.text
    assert rejeu.status_code == 200, rejeu.text
    assert rejeu.json()["balance"] == 0
    assert await _paiements(session, folio) == 1
