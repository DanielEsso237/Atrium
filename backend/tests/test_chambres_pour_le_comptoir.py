"""Les chambres a qui le comptoir peut porter, sans lire les reservations.

Sur une tablette qui ne sert qu'au bar, « Porter a la chambre » ne
proposait aucune chambre : le barman porte (`folio.charge`) mais ne lit ni
les reservations ni les ardoises. `GET /chargeable-stays` lui donne les
sejours en cours et leur ardoise ouverte -- du client, le nom et le plafond.
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


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def chambres(session, hotel_a):
    hotel, _ = hotel_a
    room_type = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    session.add(room_type)
    await session.flush()
    rooms = {n: Room(hotel_id=hotel.id, number=n, room_type_id=room_type.id) for n in ("101", "102")}
    session.add_all(rooms.values())
    await session.commit()
    return room_type, rooms


async def _sejour(client, auth, room_type, room=None, *, plafond=0):
    """Un dossier d'une nuit ; avec `room`, le client est arrive."""
    r = await client.post(
        "/api/v1/guests",
        json={
            "first_name": "Awa", "last_name": "Diallo", "phone": "+225 07 00 00 00",
            "credit_limit": plafond,
        },
        headers=auth,
    )
    assert r.status_code == 201, r.text
    guest = r.json()
    res_id, line_id, folio_id = str(uuid7()), str(uuid7()), str(uuid7())
    r = await client.post(
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
        headers=auth,
    )
    assert r.status_code == 201, r.text
    if room is not None:
        r = await client.post(
            f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in",
            json={"room_id": str(room.id), "folio_id": folio_id},
            headers=auth,
        )
        assert r.status_code == 200, r.text
    return {"stay": line_id, "folio": folio_id}


@pytest.fixture
async def auth_bar(client, session, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(session, hotel, "BARMAN", ["order.read", "order.create", "folio.charge", "cash.session"])
    return {"Authorization": f"Bearer {await login(client, 'BARMAN')}"}


async def test_le_barman_voit_les_chambres_occupees(client, auth_a, auth_bar, chambres):
    room_type, rooms = chambres
    loge = await _sejour(client, auth_a, room_type, rooms["101"], plafond=50_000)
    # Un dossier pas encore arrive : rien a porter.
    await _sejour(client, auth_a, room_type)

    r = await client.get("/api/v1/chargeable-stays", headers=auth_bar)

    assert r.status_code == 200, r.text
    sejours = r.json()
    assert [s["room_number"] for s in sejours] == ["101"]
    s = sejours[0]
    assert s["stay_id"] == loge["stay"]
    assert s["folio"]["id"] == loge["folio"]
    assert s["guest_last_name"] == "Diallo"
    assert s["guest_credit_limit"] == 50_000
    assert s["stay_status"] == "CHECKED_IN"


async def test_du_client_le_nom_et_le_plafond_seulement(client, auth_a, auth_bar, chambres):
    room_type, rooms = chambres
    await _sejour(client, auth_a, room_type, rooms["101"])

    s = (await client.get("/api/v1/chargeable-stays", headers=auth_bar)).json()[0]

    assert not any("phone" in cle or "document" in cle for cle in s)


async def test_l_ardoise_vient_entiere_pour_que_le_solde_soit_juste(
    client, auth_a, auth_bar, chambres
):
    room_type, rooms = chambres
    loge = await _sejour(client, auth_a, room_type, rooms["101"])
    r = await client.post(
        f"/api/v1/folios/{loge['folio']}/items",
        json={"id": str(uuid7()), "category": "MINIBAR", "label": "Minibar", "unit_price": 2_000},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text

    folio = (await client.get("/api/v1/chargeable-stays", headers=auth_bar)).json()[0]["folio"]

    assert [i["label"] for i in folio["items"]] == ["Minibar"]
    assert folio["balance"] == 2_000


async def test_un_client_parti_n_est_plus_propose(client, auth_a, auth_bar, chambres):
    room_type, rooms = chambres
    loge = await _sejour(client, auth_a, room_type, rooms["101"])
    r = await client.post(f"/api/v1/folios/{loge['folio']}/close", headers=auth_a)
    assert r.status_code == 200, r.text

    r = await client.get("/api/v1/chargeable-stays", headers=auth_bar)

    assert r.json() == []


async def test_sans_le_droit_de_porter_refuse(client, session, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(session, hotel, "MENAGE", ["housekeeping.read"])
    auth = {"Authorization": f"Bearer {await login(client, 'MENAGE')}"}

    r = await client.get("/api/v1/chargeable-stays", headers=auth)

    assert r.status_code == 403


async def test_un_autre_hotel_ne_voit_rien(
    client, session, auth_a, hotel_b, login, chambres
):
    room_type, rooms = chambres
    await _sejour(client, auth_a, room_type, rooms["101"])
    hotel, _ = hotel_b
    await _agent(session, hotel, "BARMAN_B", ["folio.charge"])
    auth_b = {"Authorization": f"Bearer {await login(client, 'BARMAN_B')}"}

    r = await client.get("/api/v1/chargeable-stays", headers=auth_b)

    assert r.json() == []
