"""Revenir en arriere : arrivee, depart, encaissement (demande du 16 octobre).

Une erreur de saisie se defait sur le code d'un responsable
(`operations.undo`), meme quand c'est lui qui est connecte. Rien ne s'efface :
l'arrivee rend la ligne confirmee et retire l'ardoise, le depart remet le
client dans sa chambre, l'encaissement devient un remboursement dans le
tiroir de celui qui annule. Chaque route est rejouable.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.api.v1.annulations import _reservation_status
from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import (
    Folio,
    Payment,
    Permission,
    Reservation,
    ReservationRoom,
    Role,
    RolePermission,
    Room,
    RoomType,
    User,
    UserRole,
)
from app.models.enums import OccupancyStatus, ReservationStatus

NIGHTLY = 25_000
ARRIVAL = dt.date(2030, 3, 10)
DEPARTURE = dt.date(2030, 3, 11)


# --- Sans base ------------------------------------------------------------------


def _dossier(*statuts: ReservationStatus) -> Reservation:
    return Reservation(
        rooms=[ReservationRoom(status=s, deleted_at=None) for s in statuts]
    )


def test_le_statut_du_dossier_suit_sa_ligne_la_plus_avancee():
    assert _reservation_status(_dossier(ReservationStatus.CONFIRMED)) == ReservationStatus.CONFIRMED
    assert (
        _reservation_status(_dossier(ReservationStatus.CONFIRMED, ReservationStatus.CHECKED_IN))
        == ReservationStatus.CHECKED_IN
    )
    assert _reservation_status(_dossier(ReservationStatus.CANCELLED)) == ReservationStatus.CANCELLED
    assert (
        _reservation_status(_dossier(ReservationStatus.CHECKED_OUT, ReservationStatus.CANCELLED))
        == ReservationStatus.CHECKED_OUT
    )


# --- Avec base ------------------------------------------------------------------


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def chambres(session, hotel_a):
    hotel, _ = hotel_a
    standard = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=NIGHTLY)
    session.add(standard)
    await session.flush()
    rooms = [Room(hotel_id=hotel.id, number=n, room_type_id=standard.id) for n in ("101", "102")]
    session.add_all(rooms)
    await session.commit()
    return standard, rooms


@pytest.fixture
async def receptionniste(session, hotel_a):
    """Un agent sans `operations.undo` : il ne peut pas s'autoriser."""
    hotel, _ = hotel_a
    role = Role(id=uuid.uuid4(), code="TEST_RECEP", label="Reception", is_system=True)
    session.add(role)
    await session.flush()
    for code in ("reservation.manage", "folio.write", "cash.session"):
        perm = await session.scalar(select(Permission).where(Permission.code == code))
        session.add(RolePermission(role_id=role.id, permission_id=perm.id))
    user = User(
        id=uuid.uuid4(), hotel_id=hotel.id, employee_code="RECEP_A", first_name="Awa",
        last_name="Traore", pin_hash=hash_secret("4321"), is_active=True,
        must_change_password=False,
    )
    session.add(user)
    await session.flush()
    session.add(UserRole(user_id=user.id, role_id=role.id))
    await session.commit()
    return user


async def _reserver_et_arriver(client, auth, standard, room, **extra) -> tuple[dict, str]:
    guest = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth
        )
    ).json()
    body = {
        "id": str(uuid7()),
        "guest_id": guest["id"],
        "rooms": [{
            "id": str(uuid7()), "room_type_id": str(standard.id),
            "arrival_date": str(ARRIVAL), "departure_date": str(DEPARTURE),
        }],
        **extra,
    }
    r = await client.post("/api/v1/reservations", json=body, headers=auth)
    assert r.status_code == 201, r.text
    folio_id = str(uuid7())
    r = await client.post(
        f"/api/v1/reservations/{body['id']}/rooms/{body['rooms'][0]['id']}/check-in",
        json={"room_id": str(room.id), "folio_id": folio_id},
        headers=auth,
    )
    assert r.status_code == 200, r.text
    return body, folio_id


def _ligne(body: dict) -> str:
    return f"/api/v1/reservations/{body['id']}/rooms/{body['rooms'][0]['id']}"


@pytest.mark.db
async def test_l_autorisation_verifie_le_code_et_le_droit(client, auth_a, receptionniste):
    ok = await client.post(
        "/api/v1/auth/authorize",
        json={"employee_code": "admin_a", "secret": "Test1234!", "permission": "operations.undo"},
        headers=auth_a,
    )
    assert ok.status_code == 200, ok.text
    faux = await client.post(
        "/api/v1/auth/authorize",
        json={"employee_code": "ADMIN_A", "secret": "0000", "permission": "operations.undo"},
        headers=auth_a,
    )
    # 403 et non 401 : un 401 deconnecterait l'agent de la tablette.
    assert faux.status_code == 403
    assert "incorrect" in faux.json()["detail"]
    sans_droit = await client.post(
        "/api/v1/auth/authorize",
        json={"employee_code": "RECEP_A", "secret": "4321", "permission": "operations.undo"},
        headers=auth_a,
    )
    assert sans_droit.status_code == 403


@pytest.mark.db
async def test_annuler_une_arrivee_rend_la_chambre_et_retire_l_ardoise(
    client, session, hotel_a, auth_a, chambres
):
    _, admin = hotel_a
    standard, (r101, _) = chambres
    body, folio_id = await _reserver_et_arriver(client, auth_a, standard, r101)

    corps = {"approved_by": str(admin.id), "reason": "Mauvais client"}
    r = await client.post(f"{_ligne(body)}/undo-check-in", json=corps, headers=auth_a)

    assert r.status_code == 200, r.text
    assert r.json()["status"] == "CONFIRMED"
    assert r.json()["rooms"][0]["status"] == "CONFIRMED"
    assert r.json()["rooms"][0]["checked_in_at"] is None
    # L'id avant d'expirer : lire un attribut expire recharge l'objet en
    # synchrone, ce que la session asynchrone refuse (MissingGreenlet).
    chambre_id = r101.id
    session.expire_all()
    chambre = await session.get(Room, chambre_id)
    assert chambre.occupancy_status == OccupancyStatus.VACANT
    ardoise = await session.get(Folio, uuid.UUID(folio_id))
    assert ardoise.deleted_at is not None

    # Rejeu : rien ne bouge.
    again = await client.post(f"{_ligne(body)}/undo-check-in", json=corps, headers=auth_a)
    assert again.status_code == 200, again.text

    # Une nouvelle arrivee ouvre une ardoise neuve.
    nouvelle = str(uuid7())
    r = await client.post(
        f"{_ligne(body)}/check-in",
        json={"room_id": str(r101.id), "folio_id": nouvelle},
        headers=auth_a,
    )
    assert r.status_code == 200, r.text
    assert r.json()["folio_id"] == nouvelle


@pytest.mark.db
async def test_un_responsable_sans_le_droit_est_refuse(
    client, auth_a, chambres, receptionniste
):
    standard, (r101, _) = chambres
    body, _ = await _reserver_et_arriver(client, auth_a, standard, r101)

    r = await client.post(
        f"{_ligne(body)}/undo-check-in",
        json={"approved_by": str(receptionniste.id), "reason": "Erreur"},
        headers=auth_a,
    )

    assert r.status_code == 403, r.text


@pytest.mark.db
async def test_une_arrivee_encaissee_ne_s_annule_qu_apres_l_encaissement(
    client, session, hotel_a, auth_a, chambres
):
    _, admin = hotel_a
    standard, (r101, _) = chambres
    body, folio_id = await _reserver_et_arriver(client, auth_a, standard, r101)
    r = await client.post("/api/v1/cash-sessions", json={"opening_float": 0}, headers=auth_a)
    assert r.status_code == 201, r.text
    r = await client.post(
        f"/api/v1/folios/{folio_id}/items",
        json={"id": str(uuid7()), "category": "ROOM", "label": "Nuit", "unit_price": NIGHTLY},
        headers=auth_a,
    )
    assert r.status_code in (200, 201), r.text
    paiement = str(uuid7())
    r = await client.post(
        f"/api/v1/folios/{folio_id}/payments",
        json={"id": paiement, "method": "CASH", "amount": NIGHTLY},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text

    corps = {"approved_by": str(admin.id), "reason": "Erreur"}
    r = await client.post(f"{_ligne(body)}/undo-check-in", json=corps, headers=auth_a)
    assert r.status_code == 409, r.text

    remboursement = str(uuid7())
    r = await client.post(
        f"/api/v1/payments/{paiement}/reverse",
        json={**corps, "id": remboursement},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text
    assert r.json()["balance"] == NIGHTLY
    # Rejeu du remboursement : 200, aucun second remboursement.
    r = await client.post(
        f"/api/v1/payments/{paiement}/reverse",
        json={**corps, "id": remboursement},
        headers=auth_a,
    )
    assert r.status_code == 200, r.text
    session.expire_all()
    refunds = (await session.scalars(select(Payment).where(Payment.is_refund.is_(True)))).all()
    assert [p.reverses_payment_id for p in refunds] == [uuid.UUID(paiement)]
    # Un second remboursement du meme encaissement est refuse.
    r = await client.post(
        f"/api/v1/payments/{paiement}/reverse",
        json={**corps, "id": str(uuid7())},
        headers=auth_a,
    )
    assert r.status_code == 409, r.text

    r = await client.post(f"{_ligne(body)}/undo-check-in", json=corps, headers=auth_a)
    assert r.status_code == 200, r.text


@pytest.mark.db
async def test_annuler_un_depart_remet_le_client_dans_sa_chambre(
    client, session, hotel_a, auth_a, chambres
):
    _, admin = hotel_a
    standard, (r101, _) = chambres
    body, _ = await _reserver_et_arriver(client, auth_a, standard, r101)
    r = await client.post(f"{_ligne(body)}/check-out", headers=auth_a)
    assert r.status_code == 200, r.text

    corps = {"approved_by": str(admin.id), "reason": "Depart trop tot"}
    r = await client.post(f"{_ligne(body)}/undo-check-out", json=corps, headers=auth_a)

    assert r.status_code == 200, r.text
    assert r.json()["status"] == "CHECKED_IN"
    assert r.json()["rooms"][0]["checked_out_at"] is None
    # L'id avant d'expirer : lire un attribut expire recharge l'objet en
    # synchrone, ce que la session asynchrone refuse (MissingGreenlet).
    chambre_id = r101.id
    session.expire_all()
    chambre = await session.get(Room, chambre_id)
    assert chambre.occupancy_status == OccupancyStatus.OCCUPIED
    again = await client.post(f"{_ligne(body)}/undo-check-out", json=corps, headers=auth_a)
    assert again.status_code == 200, again.text
