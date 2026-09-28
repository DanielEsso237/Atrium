"""Les arrhes passent par la caisse.

Des arrhes encaissees a la reservation etaient tracees nulle part : ni caisse,
ni ardoise. Le caissier constatait un excedent qu'il ne pouvait pas
expliquer. Elles sont desormais un vrai paiement :

- a la reservation, rattache a la reservation et a la caisse ouverte de celui
  qui encaisse -- seules les especes font monter l'attendu du tiroir ;
- a l'annulation, l'argent reste encaisse, rien n'est rembourse ;
- a l'arrivee, le paiement passe sur l'ardoise, une seule fois par dossier :
  le client ne doit plus que le reste, et la facture montre le sejour entier.

Comme partout, un renvoi repond 200 et n'encaisse jamais deux fois.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.models import FolioItem, Payment, Room, RoomType, Setting
from app.services.deposit import RULE_KEY

pytestmark = pytest.mark.db

NIGHTLY = 25_000
ARRIVAL = dt.date(2030, 3, 10)
DEPARTURE = dt.date(2030, 3, 11)  # une nuit : 25 000 F


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def rooms_a(session, hotel_a):
    hotel, _ = hotel_a
    room_type = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=NIGHTLY)
    session.add(room_type)
    await session.flush()
    rooms = [
        Room(hotel_id=hotel.id, number=n, room_type_id=room_type.id) for n in ("101", "102")
    ]
    session.add_all(rooms)
    await session.commit()
    return room_type, rooms


async def _open_cash(client, auth, opening_float=10_000) -> str:
    resp = await client.post(
        "/api/v1/cash-sessions", json={"opening_float": opening_float}, headers=auth
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def _expected(client, auth) -> int:
    return (await client.get("/api/v1/cash-sessions/current", headers=auth)).json()[
        "expected_amount"
    ]


async def _reserve(client, auth, room_type, *, rooms=1, **extra):
    guest = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth
        )
    ).json()
    body = {
        "id": str(uuid7()),
        "guest_id": guest["id"],
        "rooms": [
            {
                "id": str(uuid7()),
                "room_type_id": str(room_type.id),
                "arrival_date": str(ARRIVAL),
                "departure_date": str(DEPARTURE),
            }
            for _ in range(rooms)
        ],
        **extra,
    }
    return body, await client.post("/api/v1/reservations", json=body, headers=auth)


async def _payments(session, **where) -> list[Payment]:
    stmt = select(Payment)
    for column, value in where.items():
        stmt = stmt.where(getattr(Payment, column) == value)
    session.expire_all()
    return (await session.execute(stmt)).scalars().all()


async def _check_in(client, auth, body, line_index, room) -> str:
    folio_id = str(uuid7())
    resp = await client.post(
        f"/api/v1/reservations/{body['id']}/rooms/{body['rooms'][line_index]['id']}/check-in",
        json={"room_id": str(room.id), "folio_id": folio_id},
        headers=auth,
    )
    assert resp.status_code == 200, resp.text
    return folio_id


# --- A la reservation --------------------------------------------------------------


async def test_arrhes_en_especes_l_attendu_de_la_caisse_augmente_d_autant(
    client, session, auth_a, rooms_a
):
    cash_id = await _open_cash(client, auth_a)
    assert await _expected(client, auth_a) == 10_000

    body, resp = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=10_000, deposit_method="CASH"
    )

    assert resp.status_code == 201, resp.text
    assert resp.json()["deposit_paid_at"] is not None
    assert await _expected(client, auth_a) == 20_000
    [payment] = await _payments(session, reservation_id=uuid.UUID(body["id"]))
    assert payment.folio_id is None
    assert payment.cash_session_id == uuid.UUID(cash_id)
    assert payment.amount == 10_000


async def test_arrhes_par_carte_l_attendu_ne_bouge_pas(client, session, auth_a, rooms_a):
    await _open_cash(client, auth_a)
    body, resp = await _reserve(
        client,
        auth_a,
        rooms_a[0],
        deposit_amount=10_000,
        deposit_method="MOBILE_MONEY",
        deposit_reference="MP2809.1234",
    )
    assert resp.status_code == 201, resp.text
    assert await _expected(client, auth_a) == 10_000  # pas un franc dans le tiroir
    [payment] = await _payments(session, reservation_id=uuid.UUID(body["id"]))
    assert payment.method.value == "MOBILE_MONEY"
    assert payment.reference == "MP2809.1234"


async def test_arrhes_sans_methode_refusees(client, auth_a, rooms_a):
    _, resp = await _reserve(client, auth_a, rooms_a[0], deposit_amount=10_000)
    assert resp.status_code == 422, resp.text


async def test_arrhes_superieures_au_sejour_refusees(client, session, auth_a, rooms_a):
    _, resp = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=30_000, deposit_method="CASH"
    )
    assert resp.status_code == 422, resp.text
    assert await _payments(session) == []


async def test_regle_de_l_hotel_arrhes_dues_mais_rien_d_encaisse(
    client, session, hotel_a, auth_a, rooms_a
):
    session.add(
        Setting(hotel_id=hotel_a[0].id, key=RULE_KEY, value={"mode": "PERCENT", "rate_bp": 3000})
    )
    await session.commit()
    _, resp = await _reserve(client, auth_a, rooms_a[0])
    assert resp.status_code == 201, resp.text
    assert resp.json()["deposit_amount"] == 7_500  # 30 % de 25 000, du
    assert resp.json()["deposit_paid_at"] is None  # mais pas verse
    assert await _payments(session) == []  # aucun argent invente


# --- Annulation -------------------------------------------------------------------


async def test_annulation_apres_arrhes_l_argent_reste_encaisse(
    client, session, auth_a, rooms_a
):
    await _open_cash(client, auth_a)
    body, first = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=10_000, deposit_method="CASH"
    )
    url = f"/api/v1/reservations/{body['id']}/cancel"
    assert (await client.post(url, json={"reason": "Vol annule"}, headers=auth_a)).status_code == 200
    again = await client.post(url, json={"reason": "rejeu"}, headers=auth_a)

    assert again.status_code == 200
    assert again.json()["deposit_amount"] == 10_000
    assert again.json()["deposit_paid_at"] == first.json()["deposit_paid_at"]
    payments = await _payments(session)
    assert [(p.amount, p.is_refund, p.reservation_id) for p in payments] == [
        (10_000, False, uuid.UUID(body["id"]))
    ]
    assert await _expected(client, auth_a) == 20_000  # toujours dans le tiroir


# --- Arrivee et parcours complet -------------------------------------------------------


async def test_parcours_complet_solde_nul_et_25000_encaisses(client, session, auth_a, rooms_a):
    await _open_cash(client, auth_a)
    body, _ = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=10_000, deposit_method="CASH"
    )

    folio_id = await _check_in(client, auth_a, body, 0, rooms_a[1][0])
    await client.post(f"/api/v1/folios/{folio_id}/post-stay-nights", headers=auth_a)
    folio = (await client.get(f"/api/v1/folios/{folio_id}", headers=auth_a)).json()
    assert (folio["charges_total"], folio["payments_total"], folio["balance"]) == (
        25_000,
        10_000,
        15_000,
    )

    resp = await client.post(
        f"/api/v1/folios/{folio_id}/payments",
        json={"method": "CASH", "amount": 15_000},
        headers=auth_a,
    )
    assert resp.status_code == 201, resp.text
    resp = await client.post(
        f"/api/v1/reservations/{body['id']}/rooms/{body['rooms'][0]['id']}/check-out",
        headers=auth_a,
    )
    assert resp.status_code == 200, resp.text

    folio = (await client.get(f"/api/v1/folios/{folio_id}", headers=auth_a)).json()
    assert folio["balance"] == 0
    payments = await _payments(session)
    assert sum(p.amount for p in payments) == 25_000
    assert all(p.folio_id == uuid.UUID(folio_id) and p.reservation_id is None for p in payments)
    # Des arrhes sont un paiement, pas une remise : la facture et le chiffre
    # d'affaires montrent le sejour entier.
    items = (await session.execute(select(FolioItem))).scalars().all()
    assert sum(i.amount for i in items) == 25_000
    assert await _expected(client, auth_a) == 10_000 + 25_000


async def test_groupe_les_arrhes_ne_passent_qu_une_fois_sur_l_ardoise(
    client, session, auth_a, rooms_a
):
    body, resp = await _reserve(
        client, auth_a, rooms_a[0], rooms=2, deposit_amount=20_000, deposit_method="CASH"
    )
    assert resp.status_code == 201, resp.text
    folio_1 = await _check_in(client, auth_a, body, 0, rooms_a[1][0])
    folio_2 = await _check_in(client, auth_a, body, 1, rooms_a[1][1])

    payments = await _payments(session)
    assert len(payments) == 1 and payments[0].folio_id == uuid.UUID(folio_1)
    second = (await client.get(f"/api/v1/folios/{folio_2}", headers=auth_a)).json()
    assert second["payments_total"] == 0


# --- Rejouable ------------------------------------------------------------------------


async def test_reservation_avec_arrhes_rejouee_n_encaisse_pas_deux_fois(
    client, session, auth_a, rooms_a
):
    await _open_cash(client, auth_a)
    body, first = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=10_000, deposit_method="CASH"
    )
    again = await client.post("/api/v1/reservations", json=body, headers=auth_a)

    assert (first.status_code, again.status_code) == (201, 200), again.text
    assert len(await _payments(session)) == 1
    assert await _expected(client, auth_a) == 20_000


async def test_check_in_rejoue_ne_transfere_pas_deux_fois(client, session, auth_a, rooms_a):
    body, _ = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=10_000, deposit_method="CASH"
    )
    room = rooms_a[1][0]
    folio_id = await _check_in(client, auth_a, body, 0, room)
    again = await client.post(
        f"/api/v1/reservations/{body['id']}/rooms/{body['rooms'][0]['id']}/check-in",
        json={"room_id": str(room.id), "folio_id": folio_id},
        headers=auth_a,
    )
    assert again.status_code == 200, again.text
    folio = (await client.get(f"/api/v1/folios/{folio_id}", headers=auth_a)).json()
    assert folio["payments_total"] == 10_000
    assert len(await _payments(session)) == 1
