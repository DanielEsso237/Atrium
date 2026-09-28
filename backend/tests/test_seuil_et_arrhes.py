"""Seuil de consommation et arrhes.

Deux regles d'argent cote serveur. `guests.credit_limit` et
`reservations.deposit_amount` existaient des deux cotes sans que personne ne
les lise.

Le seuil n'est pas un blocage mais une autorisation : au-dela, un responsable
peut laisser passer la charge, et son nom reste sur la ligne. Les arrhes
restent acquises a l'annulation et se deduisent de l'ardoise a l'arrivee.

Comme partout, un renvoi repond 200 : la tablette renvoie ce dont elle n'a
pas recu la reponse, et un refus bloquerait sa file d'envoi.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import FolioItem, Payment, Room, RoomType, Setting, User
from app.models.enums import ChargeCategory
from app.services.deposit import RULE_KEY

pytestmark = pytest.mark.db

ARRIVAL = dt.date(2030, 3, 10)
DEPARTURE = dt.date(2030, 3, 12)
SEUIL = 50_000


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def _room_type(session, hotel) -> tuple[RoomType, Room]:
    room_type = RoomType(
        hotel_id=hotel.id, code=f"T{hotel.code}", label="Standard", default_rate=25_000
    )
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number=f"1{hotel.code}", room_type_id=room_type.id)
    session.add(room)
    await session.commit()
    return room_type, room


async def _folio(client, session, hotel, auth, credit_limit: int) -> str:
    """Un client au seuil donne, arrive, avec son ardoise ouverte et vide."""
    _, room = await _room_type(session, hotel)
    guest = (
        await client.post(
            "/api/v1/guests",
            json={"first_name": "Awa", "last_name": "Diallo", "credit_limit": credit_limit},
            headers=auth,
        )
    ).json()
    res = (
        await client.post(
            "/api/v1/reservations",
            json={
                "guest_id": guest["id"],
                "rooms": [{
                    "room_type_id": str(room.room_type_id),
                    "arrival_date": str(ARRIVAL),
                    "departure_date": str(DEPARTURE),
                }],
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
    return str(folio_id)


def _charge(amount: int, **extra) -> dict:
    return {
        "id": str(uuid7()),
        "category": "MINIBAR",
        "label": "Consommation",
        "unit_price": amount,
        **extra,
    }


async def _post(client, folio_id, body, auth):
    return await client.post(f"/api/v1/folios/{folio_id}/items", json=body, headers=auth)


# --- Seuil ---------------------------------------------------------------------


async def test_atteindre_exactement_le_seuil_est_permis(client, session, hotel_a, auth_a):
    folio_id = await _folio(client, session, hotel_a[0], auth_a, SEUIL)
    assert (await _post(client, folio_id, _charge(30_000), auth_a)).status_code == 201
    resp = await _post(client, folio_id, _charge(20_000), auth_a)
    assert resp.status_code == 201, resp.text


async def test_au_dessus_du_seuil_refuse_avec_un_message_lisible(
    client, session, hotel_a, auth_a
):
    folio_id = await _folio(client, session, hotel_a[0], auth_a, SEUIL)
    await _post(client, folio_id, _charge(45_000), auth_a)

    resp = await _post(client, folio_id, _charge(10_000), auth_a)

    assert resp.status_code == 409
    detail = resp.json()["detail"]
    assert isinstance(detail, str)  # la tablette affiche une chaine
    for attendu in ("45 000 F", "10 000 F", "55 000 F", "50 000 F", "5 000 F"):
        assert attendu in detail, detail
    folio = (await client.get(f"/api/v1/folios/{folio_id}", headers=auth_a)).json()
    assert folio["balance"] == 45_000  # rien n'a ete porte


async def test_depassement_autorise_par_un_responsable_et_trace(
    client, session, hotel_a, auth_a
):
    hotel, manager = hotel_a
    folio_id = await _folio(client, session, hotel, auth_a, SEUIL)
    await _post(client, folio_id, _charge(45_000), auth_a)

    body = _charge(10_000, override_by=str(manager.id))
    resp = await _post(client, folio_id, body, auth_a)

    assert resp.status_code == 201, resp.text
    assert resp.json()["override_by"] == str(manager.id)
    item = await session.get(FolioItem, uuid.UUID(body["id"]))
    assert item.override_by == manager.id


async def test_autorisation_par_quelqu_un_sans_le_droit_refusee(
    client, session, hotel_a, auth_a
):
    hotel, _ = hotel_a
    receptionniste = User(
        hotel_id=hotel.id,
        employee_code="RECEP_A",
        first_name="Sans",
        last_name="Droit",
        password_hash=hash_secret("Test1234!"),
        is_active=True,
        must_change_password=False,
    )
    session.add(receptionniste)
    await session.commit()
    folio_id = await _folio(client, session, hotel, auth_a, SEUIL)
    await _post(client, folio_id, _charge(45_000), auth_a)

    resp = await _post(client, folio_id, _charge(10_000, override_by=str(receptionniste.id)), auth_a)
    assert resp.status_code == 403, resp.text

    resp = await _post(client, folio_id, _charge(10_000, override_by=str(uuid.uuid4())), auth_a)
    assert resp.status_code == 403, resp.text


async def test_seuil_nul_veut_dire_pas_de_limite(client, session, hotel_a, auth_a):
    folio_id = await _folio(client, session, hotel_a[0], auth_a, 0)
    resp = await _post(client, folio_id, _charge(5_000_000), auth_a)
    assert resp.status_code == 201, resp.text
    assert resp.json()["override_by"] is None


async def test_la_fiche_renvoyee_sans_seuil_ne_l_efface_pas(client, session, hotel_a, auth_a):
    guest_id = str(uuid7())
    body = {"id": guest_id, "first_name": "Awa", "last_name": "Diallo", "credit_limit": SEUIL}
    assert (await client.post("/api/v1/guests", json=body, headers=auth_a)).status_code == 201
    # Ce que la tablette renvoie : la fiche, sans le seuil.
    del body["credit_limit"]
    again = await client.post("/api/v1/guests", json=body, headers=auth_a)
    assert again.status_code == 200
    assert again.json()["credit_limit"] == SEUIL


async def test_charge_rejouee_apres_depassement_repond_200(client, session, hotel_a, auth_a):
    """Passee une fois (sous le seuil), renvoyee alors que l'ardoise l'a depasse."""
    hotel, manager = hotel_a
    folio_id = await _folio(client, session, hotel, auth_a, SEUIL)
    premiere = _charge(40_000)
    assert (await _post(client, folio_id, premiere, auth_a)).status_code == 201
    autorisee = _charge(20_000, override_by=str(manager.id))
    assert (await _post(client, folio_id, autorisee, auth_a)).status_code == 201

    for body in (premiere, autorisee):
        resp = await _post(client, folio_id, body, auth_a)
        assert resp.status_code == 200, resp.text
    folio = (await client.get(f"/api/v1/folios/{folio_id}", headers=auth_a)).json()
    assert folio["balance"] == 60_000
    rows = (await session.execute(select(FolioItem).where(FolioItem.folio_id == uuid.UUID(folio_id)))).scalars().all()
    assert len(rows) == 2


# --- Arrhes ----------------------------------------------------------------------


async def _reservation(client, auth, guest_id, room_type_id, rooms=1, **extra):
    lines = [
        {
            "id": str(uuid7()),
            "room_type_id": str(room_type_id),
            "arrival_date": str(ARRIVAL),
            "departure_date": str(DEPARTURE),
        }
        for _ in range(rooms)
    ]
    body = {"id": str(uuid7()), "guest_id": guest_id, "rooms": lines, **extra}
    resp = await client.post("/api/v1/reservations", json=body, headers=auth)
    return body, resp


async def _guest(client, auth) -> str:
    resp = await client.post(
        "/api/v1/guests", json={"first_name": "Paul", "last_name": "Mbarga"}, headers=auth
    )
    return resp.json()["id"]


async def _deux_chambres(session, hotel) -> tuple[RoomType, list[Room]]:
    room_type, room = await _room_type(session, hotel)
    other = Room(hotel_id=hotel.id, number=f"2{hotel.code}", room_type_id=room_type.id)
    session.add(other)
    await session.commit()
    return room_type, [room, other]


async def _deposit_items(session, reservation_id: str) -> list[FolioItem]:
    return (
        await session.execute(
            select(FolioItem).where(
                FolioItem.source_table == "reservations",
                FolioItem.source_id == uuid.UUID(reservation_id),
            )
        )
    ).scalars().all()


async def test_arrhes_saisies_enregistrees(client, session, hotel_a, auth_a):
    room_type, _ = await _room_type(session, hotel_a[0])
    _, resp = await _reservation(client, auth_a, await _guest(client, auth_a), room_type.id, deposit_amount=20_000)
    assert resp.status_code == 201, resp.text
    assert resp.json()["deposit_amount"] == 20_000
    assert resp.json()["deposit_paid_at"] is not None


async def test_arrhes_calculees_par_la_regle_de_l_hotel(client, session, hotel_a, auth_a):
    hotel, _ = hotel_a
    session.add(
        Setting(hotel_id=hotel.id, key=RULE_KEY, value={"mode": "PERCENT", "rate_bp": 3000})
    )
    await session.commit()
    room_type, _ = await _room_type(session, hotel)
    _, resp = await _reservation(client, auth_a, await _guest(client, auth_a), room_type.id)
    assert resp.status_code == 201, resp.text
    assert resp.json()["estimated_total"] == 50_000
    assert resp.json()["deposit_amount"] == 15_000


async def test_sans_regle_ni_saisie_pas_d_arrhes(client, session, hotel_a, auth_a):
    room_type, _ = await _room_type(session, hotel_a[0])
    _, resp = await _reservation(client, auth_a, await _guest(client, auth_a), room_type.id)
    assert resp.json()["deposit_amount"] == 0
    assert resp.json()["deposit_paid_at"] is None


async def test_arrhes_superieures_au_sejour_refusees(client, session, hotel_a, auth_a):
    room_type, _ = await _room_type(session, hotel_a[0])
    _, resp = await _reservation(client, auth_a, await _guest(client, auth_a), room_type.id, deposit_amount=60_000)
    assert resp.status_code == 422, resp.text


async def test_annulation_apres_arrhes_les_arrhes_restent_acquises(
    client, session, hotel_a, auth_a
):
    room_type, _ = await _room_type(session, hotel_a[0])
    body, resp = await _reservation(client, auth_a, await _guest(client, auth_a), room_type.id, deposit_amount=20_000)
    url = f"/api/v1/reservations/{body['id']}/cancel"

    cancelled = await client.post(url, json={"reason": "Vol annule"}, headers=auth_a)
    again = await client.post(url, json={"reason": "rejeu"}, headers=auth_a)

    assert cancelled.status_code == again.status_code == 200
    assert again.json()["status"] == "CANCELLED"
    assert again.json()["deposit_amount"] == 20_000
    assert again.json()["deposit_paid_at"] == resp.json()["deposit_paid_at"]
    payments = (await session.execute(select(Payment))).scalars().all()
    assert payments == []  # aucun remboursement emis


async def test_arrivee_apres_arrhes_le_client_ne_paie_que_le_reste(
    client, session, hotel_a, auth_a
):
    room_type, room = await _room_type(session, hotel_a[0])
    body, _ = await _reservation(client, auth_a, await _guest(client, auth_a), room_type.id, deposit_amount=20_000)
    folio_id = uuid7()
    url = f"/api/v1/reservations/{body['id']}/rooms/{body['rooms'][0]['id']}/check-in"
    check_in = {"room_id": str(room.id), "folio_id": str(folio_id)}

    assert (await client.post(url, json=check_in, headers=auth_a)).status_code == 200
    again = await client.post(url, json=check_in, headers=auth_a)  # rejeu
    assert again.status_code == 200, again.text

    items = await _deposit_items(session, body["id"])
    assert len(items) == 1
    assert items[0].category == ChargeCategory.DEPOSIT and items[0].amount == -20_000
    await client.post(f"/api/v1/folios/{folio_id}/post-stay-nights", headers=auth_a)
    folio = (await client.get(f"/api/v1/folios/{folio_id}", headers=auth_a)).json()
    assert folio["charges_total"] == 50_000 - 20_000
    assert folio["balance"] == 30_000  # reste du


async def test_groupe_les_arrhes_ne_se_deduisent_qu_une_fois(client, session, hotel_a, auth_a):
    room_type, rooms = await _deux_chambres(session, hotel_a[0])
    body, resp = await _reservation(
        client, auth_a, await _guest(client, auth_a), room_type.id, rooms=2, deposit_amount=40_000
    )
    assert resp.status_code == 201, resp.text
    for line, room in zip(body["rooms"], rooms):
        resp = await client.post(
            f"/api/v1/reservations/{body['id']}/rooms/{line['id']}/check-in",
            json={"room_id": str(room.id)},
            headers=auth_a,
        )
        assert resp.status_code == 200, resp.text
    assert len(await _deposit_items(session, body["id"])) == 1


async def test_reservation_avec_arrhes_rejouee_repond_200(client, session, hotel_a, auth_a):
    """Le renvoi arrive quand l'hotel est complet : 200, et rien de recompte."""
    room_type, _ = await _room_type(session, hotel_a[0])
    body, first = await _reservation(client, auth_a, await _guest(client, auth_a), room_type.id, deposit_amount=20_000)
    again = await client.post("/api/v1/reservations", json=body, headers=auth_a)
    assert (first.status_code, again.status_code) == (201, 200), again.text
    assert again.json()["deposit_amount"] == 20_000
    assert again.json()["reference"] == first.json()["reference"]
