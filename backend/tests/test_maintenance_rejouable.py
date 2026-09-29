"""Les tickets de maintenance rejouables, avec les identifiants de la tablette.

Meme exigence que pour le menage : le ticket nait sur la tablette, souvent la
ou le wifi ne passe pas (la chaufferie, le sous-sol, la chambre du fond). Il
porte donc son id, et un renvoi ne doit ni ouvrir un second ticket -- ni
imprimer un second bon de travail -- ni repondre 409, qui bloquerait la file
d'envoi et toutes les ecritures derriere elle.

Les transitions de meme : « je m'en occupe », « resolu », « clos » peuvent
partir deux fois.
"""

from __future__ import annotations

import pytest
from sqlalchemy import func, select

from app.core.ids import uuid7
from app.models import MaintenanceTicket, Room, RoomType, User

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def auth_b(client, hotel_b, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_B')}"}


async def _chambre(session, hotel) -> Room:
    room_type = RoomType(
        hotel_id=hotel.id, code=f"M{hotel.code}", label="Standard", default_rate=25_000
    )
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number=f"9{hotel.code}", room_type_id=room_type.id)
    session.add(room)
    await session.commit()
    return room


def _corps(room_id, ticket_id=None, bloque=True) -> dict:
    corps = {
        "room_id": str(room_id),
        "title": "Fuite sous le lavabo",
        "priority": "HIGH",
        "blocks_room": bloque,
    }
    if ticket_id:
        corps["id"] = str(ticket_id)
    return corps


async def _compte(session, room_id) -> int:
    return await session.scalar(
        select(func.count())
        .select_from(MaintenanceTicket)
        .where(MaintenanceTicket.room_id == room_id)
    )


async def test_deux_creations_meme_id_un_seul_ticket(client, session, hotel_a, auth_a):
    room = await _chambre(session, hotel_a[0])
    ticket_id = uuid7()

    premier = await client.post(
        "/api/v1/maintenance-tickets", json=_corps(room.id, ticket_id), headers=auth_a
    )
    rejeu = await client.post(
        "/api/v1/maintenance-tickets", json=_corps(room.id, ticket_id), headers=auth_a
    )

    assert premier.status_code == 201, premier.text
    assert rejeu.status_code == 200, rejeu.text
    assert premier.json()["id"] == rejeu.json()["id"] == str(ticket_id)
    assert premier.json()["number"] == rejeu.json()["number"]
    assert await _compte(session, room.id) == 1


async def test_sans_id_le_serveur_numerote_comme_avant(client, session, hotel_a, auth_a):
    room = await _chambre(session, hotel_a[0])

    a = await client.post("/api/v1/maintenance-tickets", json=_corps(room.id), headers=auth_a)
    b = await client.post("/api/v1/maintenance-tickets", json=_corps(room.id), headers=auth_a)

    assert (a.status_code, b.status_code) == (201, 201)
    assert a.json()["id"] != b.json()["id"]
    assert await _compte(session, room.id) == 2


async def test_un_ticket_d_un_autre_hotel_repond_404(
    client, session, hotel_a, hotel_b, auth_a, auth_b
):
    chambre_b = await _chambre(session, hotel_b[0])
    ticket_id = uuid7()
    sien = await client.post(
        "/api/v1/maintenance-tickets", json=_corps(chambre_b.id, ticket_id), headers=auth_b
    )
    assert sien.status_code == 201, sien.text

    chambre_a = await _chambre(session, hotel_a[0])
    resp = await client.post(
        "/api/v1/maintenance-tickets", json=_corps(chambre_a.id, ticket_id), headers=auth_a
    )
    assert resp.status_code == 404, resp.text


async def test_le_cycle_complet_est_rejouable(client, session, hotel_a, auth_a):
    """Chaque etape part deux fois ; la chambre sort puis revient a la vente."""
    room = await _chambre(session, hotel_a[0])
    ticket_id = uuid7()
    await client.post(
        "/api/v1/maintenance-tickets", json=_corps(room.id, ticket_id), headers=auth_a
    )
    await session.refresh(room)
    assert room.is_out_of_order is True

    admin = await session.scalar(select(User).where(User.employee_code == "ADMIN_A"))
    base = f"/api/v1/maintenance-tickets/{ticket_id}"

    for _ in range(2):
        pris = await client.post(
            f"{base}/assign", json={"user_id": str(admin.id)}, headers=auth_a
        )
        assert pris.status_code == 200, pris.text
        assert pris.json()["status"] == "ASSIGNED"

    for _ in range(2):
        resolu = await client.post(
            f"{base}/resolve", json={"resolution": "Joint change"}, headers=auth_a
        )
        assert resolu.status_code == 200, resolu.text
        assert resolu.json()["status"] == "RESOLVED"

    for _ in range(2):
        clos = await client.post(f"{base}/close", headers=auth_a)
        assert clos.status_code == 200, clos.text
        assert clos.json()["status"] == "CLOSED"

    await session.refresh(room)
    assert room.is_out_of_order is False


async def test_un_vrai_conflit_reste_un_conflit(client, session, hotel_a, auth_a):
    """Rejouer n'est pas tout accepter : clore un ticket jamais resolu reste

    une incoherence, et doit se voir.
    """
    room = await _chambre(session, hotel_a[0])
    ticket_id = uuid7()
    await client.post(
        "/api/v1/maintenance-tickets", json=_corps(room.id, ticket_id), headers=auth_a
    )

    resp = await client.post(f"/api/v1/maintenance-tickets/{ticket_id}/close", headers=auth_a)
    assert resp.status_code == 409, resp.text
