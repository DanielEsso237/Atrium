"""Le menage rejouable, avec les identifiants de la tablette.

Meme exigence que pour les clients, les reservations et les ardoises : la
tache de menage nait sur la tablette de la reception, au depart du client.
Elle porte donc son id, et un renvoi ne doit ni creer un doublon -- l'hotel se
retrouverait avec deux fois le meme menage a faire -- ni repondre 409, qui
bloquerait la file d'envoi et toutes les ecritures derriere elle.

Les transitions comptent autant que la creation : la femme de chambre appuie
sur « Commencer » dans un couloir, l'ascenseur coupe le wifi, la tablette
renvoie. Demarrer une tache deja demarree doit repondre 200.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import func, select

from app.core.ids import uuid7
from app.models import HousekeepingTask, Room, RoomType

pytestmark = pytest.mark.db

JOUR = dt.date(2030, 3, 10)


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def auth_b(client, hotel_b, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_B')}"}


async def _chambre(session, hotel) -> Room:
    room_type = RoomType(
        hotel_id=hotel.id, code=f"T{hotel.code}", label="Standard", default_rate=25_000
    )
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number=f"1{hotel.code}", room_type_id=room_type.id)
    session.add(room)
    await session.commit()
    return room


def _corps(room_id, task_id=None) -> dict:
    corps = {
        "room_id": str(room_id),
        "type": "DEPARTURE",
        "business_date": str(JOUR),
    }
    if task_id:
        corps["id"] = str(task_id)
    return corps


async def _compte(session, room_id) -> int:
    return await session.scalar(
        select(func.count())
        .select_from(HousekeepingTask)
        .where(HousekeepingTask.room_id == room_id)
    )


async def test_deux_creations_meme_id_une_seule_tache(client, session, hotel_a, auth_a):
    room = await _chambre(session, hotel_a[0])
    task_id = uuid7()

    premier = await client.post(
        "/api/v1/housekeeping-tasks", json=_corps(room.id, task_id), headers=auth_a
    )
    rejeu = await client.post(
        "/api/v1/housekeeping-tasks", json=_corps(room.id, task_id), headers=auth_a
    )

    assert premier.status_code == 201, premier.text
    assert rejeu.status_code == 200, rejeu.text
    assert premier.json()["id"] == rejeu.json()["id"] == str(task_id)
    assert await _compte(session, room.id) == 1


async def test_sans_id_le_serveur_numerote_comme_avant(client, session, hotel_a, auth_a):
    room = await _chambre(session, hotel_a[0])

    a = await client.post("/api/v1/housekeeping-tasks", json=_corps(room.id), headers=auth_a)
    b = await client.post("/api/v1/housekeeping-tasks", json=_corps(room.id), headers=auth_a)

    assert (a.status_code, b.status_code) == (201, 201)
    assert a.json()["id"] != b.json()["id"]
    assert await _compte(session, room.id) == 2


async def test_une_tache_d_un_autre_hotel_repond_404(client, session, hotel_a, hotel_b, auth_a, auth_b):
    chambre_b = await _chambre(session, hotel_b[0])
    task_id = uuid7()
    sienne = await client.post(
        "/api/v1/housekeeping-tasks", json=_corps(chambre_b.id, task_id), headers=auth_b
    )
    assert sienne.status_code == 201, sienne.text

    chambre_a = await _chambre(session, hotel_a[0])
    resp = await client.post(
        "/api/v1/housekeeping-tasks", json=_corps(chambre_a.id, task_id), headers=auth_a
    )
    assert resp.status_code == 404, resp.text


async def test_demarrer_et_terminer_sont_rejouables(client, session, hotel_a, auth_a):
    """Le cas du couloir : elle appuie, le wifi tombe, la tablette renvoie."""
    room = await _chambre(session, hotel_a[0])
    task_id = uuid7()
    await client.post("/api/v1/housekeeping-tasks", json=_corps(room.id, task_id), headers=auth_a)
    base = f"/api/v1/housekeeping-tasks/{task_id}"

    demarre = await client.post(f"{base}/start", headers=auth_a)
    encore = await client.post(f"{base}/start", headers=auth_a)
    assert demarre.status_code == 200, demarre.text
    assert encore.status_code == 200, encore.text
    assert encore.json()["status"] == "IN_PROGRESS"

    fini = await client.post(f"{base}/finish", headers=auth_a)
    refini = await client.post(f"{base}/finish", headers=auth_a)
    assert fini.status_code == 200, fini.text
    assert refini.status_code == 200, refini.text
    assert refini.json()["status"] == "DONE"

    # Le renvoi ne doit pas rallonger la duree : elle est figee a la premiere
    # fin. Sans ca, une tablette qui renvoie dix minutes plus tard ferait
    # croire a dix minutes de menage de plus.
    assert fini.json()["duration_minutes"] == refini.json()["duration_minutes"]


async def test_terminer_remet_la_chambre_propre(client, session, hotel_a, auth_a):
    room = await _chambre(session, hotel_a[0])
    task_id = uuid7()
    await client.post("/api/v1/housekeeping-tasks", json=_corps(room.id, task_id), headers=auth_a)
    base = f"/api/v1/housekeeping-tasks/{task_id}"

    await client.post(f"{base}/start", headers=auth_a)
    await session.refresh(room)
    assert room.housekeeping_status.value == "IN_PROGRESS"

    await client.post(f"{base}/finish", headers=auth_a)
    await session.refresh(room)
    assert room.housekeeping_status.value == "CLEAN"


async def test_un_vrai_conflit_reste_un_conflit(client, session, hotel_a, auth_a):
    """Rejouer n'est pas tout accepter : terminer sans avoir commence reste

    une incoherence, et doit se voir.
    """
    room = await _chambre(session, hotel_a[0])
    task_id = uuid7()
    await client.post("/api/v1/housekeeping-tasks", json=_corps(room.id, task_id), headers=auth_a)

    resp = await client.post(
        f"/api/v1/housekeeping-tasks/{task_id}/finish", headers=auth_a
    )
    assert resp.status_code == 409, resp.text
