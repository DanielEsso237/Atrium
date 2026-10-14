"""Le surclassement : une chambre d'une autre categorie que celle reservee.

A l'arrivee, le client recoit une chambre d'une categorie superieure. Par
defaut il garde le tarif reserve (surclassement offert) ; au cas par cas, le
tarif de la nouvelle categorie s'applique. Le motif est note, la categorie
reservee est gardee, et la disponibilite se compte la ou le client dort.

Les chiffres : une Standard a 25 000, une Suite a 60 000, deux nuits.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import (
    Permission,
    ReservationRoom,
    Role,
    RolePermission,
    Room,
    RoomType,
    StayNight,
    User,
    UserRole,
)
from app.models.enums import OccupancyStatus

pytestmark = pytest.mark.db

ARRIVAL = dt.date(2030, 3, 10)
DEPARTURE = dt.date(2030, 3, 12)
OFFERT = {"reason": "Standard en travaux"}
PAYANT = {"keep_rate": False, "reason": "Le client prefere la suite"}


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def chambres(session, hotel_a):
    """Deux standards et une suite, propres et libres ; rend leurs identifiants."""
    hotel, _ = hotel_a
    standard = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    suite = RoomType(hotel_id=hotel.id, code="STE", label="Suite", default_rate=60_000)
    session.add_all([standard, suite])
    await session.flush()
    r101 = Room(hotel_id=hotel.id, number="101", room_type_id=standard.id)
    r102 = Room(hotel_id=hotel.id, number="102", room_type_id=standard.id)
    r501 = Room(hotel_id=hotel.id, number="501", room_type_id=suite.id)
    session.add_all([r101, r102, r501])
    await session.commit()
    return {
        "standard": str(standard.id), "suite": str(suite.id),
        "101": str(r101.id), "102": str(r102.id), "501": str(r501.id),
    }


async def _reserver(client, auth, room_type: str) -> tuple[str, str]:
    """Reserve deux nuits dans cette categorie ; rend dossier et ligne."""
    guest = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth
        )
    ).json()
    res_id, line_id = str(uuid7()), str(uuid7())
    r = await client.post(
        "/api/v1/reservations",
        json={
            "id": res_id,
            "guest_id": guest["id"],
            "rooms": [
                {
                    "id": line_id,
                    "room_type_id": room_type,
                    "arrival_date": str(ARRIVAL),
                    "departure_date": str(DEPARTURE),
                }
            ],
        },
        headers=auth,
    )
    assert r.status_code in (200, 201), r.text
    return res_id, line_id


async def _arriver(client, auth, res_id, line_id, room, upgrade=None, folio_id=None):
    corps = {"room_id": room, "folio_id": folio_id or str(uuid7())}
    if upgrade is not None:
        corps["upgrade"] = upgrade
    return await client.post(
        f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in", json=corps, headers=auth
    )


async def _ligne(session, line_id: str) -> ReservationRoom:
    session.expire_all()
    return await session.get(ReservationRoom, uuid.UUID(line_id))


async def _nuits(session, line_id: str) -> list[int]:
    session.expire_all()
    nuits = await session.scalars(
        select(StayNight)
        .where(StayNight.reservation_room_id == uuid.UUID(line_id), StayNight.deleted_at.is_(None))
        .order_by(StayNight.business_date)
    )
    return [n.rate for n in nuits]


async def _occupation(session, room_id: str) -> OccupancyStatus:
    session.expire_all()
    return (await session.get(Room, uuid.UUID(room_id))).occupancy_status


# --- A l'arrivee ----------------------------------------------------------------


async def test_surclassement_offert_le_tarif_reserve_reste(
    client, session, hotel_a, auth_a, chambres
):
    _, admin = hotel_a
    admin_id = admin.id
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])

    r = await _arriver(client, auth_a, res_id, line_id, chambres["501"], OFFERT)

    assert r.status_code == 200, r.text
    (ligne,) = r.json()["rooms"]
    assert ligne["status"] == "CHECKED_IN"
    assert ligne["room_id"] == chambres["501"]
    # La ligne est dans la categorie de la chambre ; la reservee est gardee.
    assert ligne["room_type_id"] == chambres["suite"]
    assert ligne["booked_room_type_id"] == chambres["standard"]
    assert ligne["upgrade_reason"] == "Standard en travaux"
    assert ligne["upgraded_by"] == str(admin_id)
    # Offert : 2 nuits a 25 000.
    assert ligne["nightly_rate"] == 25_000
    assert r.json()["estimated_total"] == 50_000
    assert await _nuits(session, line_id) == [25_000, 25_000]
    assert await _occupation(session, chambres["501"]) == OccupancyStatus.OCCUPIED


async def test_surclassement_payant_le_tarif_de_la_nouvelle_categorie(
    client, session, auth_a, chambres
):
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])

    r = await _arriver(client, auth_a, res_id, line_id, chambres["501"], PAYANT)

    assert r.status_code == 200, r.text
    (ligne,) = r.json()["rooms"]
    assert ligne["room_type_id"] == chambres["suite"]
    assert ligne["booked_room_type_id"] == chambres["standard"]
    # 2 nuits a 60 000.
    assert ligne["nightly_rate"] == 60_000
    assert r.json()["estimated_total"] == 120_000
    assert await _nuits(session, line_id) == [60_000, 60_000]


async def test_sans_le_droit_pas_de_surclassement_payant(
    client, session, hotel_a, login, auth_a, chambres
):
    """Appliquer un autre tarif change le prix du sejour : il faut
    `reservation.manage`. Rien n'est ecrit par le refus."""
    hotel, _ = hotel_a
    role = Role(id=uuid.uuid4(), code="R_ACCUEIL", label="Accueil", is_system=False)
    session.add(role)
    await session.flush()
    for code in ("reservation.read", "reservation.create"):
        perm = await session.scalar(select(Permission).where(Permission.code == code))
        session.add(RolePermission(role_id=role.id, permission_id=perm.id))
    agent = User(
        id=uuid.uuid4(), hotel_id=hotel.id, employee_code="ACCUEIL_A",
        first_name="Test", last_name="Accueil",
        password_hash=hash_secret("Test1234!"), is_active=True, must_change_password=False,
    )
    session.add(agent)
    await session.flush()
    session.add(UserRole(user_id=agent.id, role_id=role.id))
    await session.commit()
    accueil = {"Authorization": f"Bearer {await login(client, 'ACCUEIL_A')}"}
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])

    r = await _arriver(client, accueil, res_id, line_id, chambres["501"], PAYANT)

    assert r.status_code == 403, r.text
    ligne = await _ligne(session, line_id)
    assert str(ligne.room_type_id) == chambres["standard"]
    assert ligne.booked_room_type_id is None
    assert ligne.nightly_rate == 25_000
    assert await _occupation(session, chambres["501"]) == OccupancyStatus.VACANT


async def test_sans_upgrade_une_autre_categorie_reste_refusee(
    client, session, auth_a, chambres
):
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])

    r = await _arriver(client, auth_a, res_id, line_id, chambres["501"])
    assert r.status_code == 422
    assert await _occupation(session, chambres["501"]) == OccupancyStatus.VACANT

    # La meme categorie, sans `upgrade` : comme avant.
    r = await _arriver(client, auth_a, res_id, line_id, chambres["101"])
    assert r.status_code == 200, r.text
    (ligne,) = r.json()["rooms"]
    assert ligne["room_type_id"] == chambres["standard"]
    assert (ligne["booked_room_type_id"], ligne["upgrade_reason"]) == (None, None)


async def test_un_surclassement_va_vers_une_autre_categorie(client, session, auth_a, chambres):
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])

    r = await _arriver(client, auth_a, res_id, line_id, chambres["101"], OFFERT)

    assert r.status_code == 422
    assert await _occupation(session, chambres["101"]) == OccupancyStatus.VACANT


async def test_le_motif_est_obligatoire(client, auth_a, chambres):
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])

    for upgrade in ({}, {"reason": "   "}, {"reason": "x" * 256}):
        r = await _arriver(client, auth_a, res_id, line_id, chambres["501"], upgrade)
        assert r.status_code == 422, upgrade


async def test_le_check_in_surclasse_se_rejoue(client, session, auth_a, chambres):
    """Renvoye par la file : 200, la meme ardoise, et rien de refait."""
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])
    folio_id = str(uuid7())

    premier = await _arriver(client, auth_a, res_id, line_id, chambres["501"], PAYANT, folio_id)
    second = await _arriver(client, auth_a, res_id, line_id, chambres["501"], PAYANT, folio_id)

    assert (premier.status_code, second.status_code) == (200, 200)
    assert second.json()["folio_id"] == premier.json()["folio_id"] == folio_id
    (ligne,) = second.json()["rooms"]
    assert ligne["booked_room_type_id"] == chambres["standard"]
    assert ligne["nightly_rate"] == 60_000
    assert second.json()["estimated_total"] == 120_000


async def test_la_chambre_est_prise_dans_la_nouvelle_categorie(client, auth_a, chambres):
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])

    async def reservees(categorie: str) -> int:
        r = await client.get(
            "/api/v1/reservations/availability",
            params={"room_type_id": categorie, "arrival_date": str(ARRIVAL),
                    "departure_date": str(DEPARTURE)},
            headers=auth_a,
        )
        assert r.status_code == 200, r.text
        return r.json()["booked_rooms"]

    assert (await reservees(chambres["standard"]), await reservees(chambres["suite"])) == (1, 0)

    r = await _arriver(client, auth_a, res_id, line_id, chambres["501"], OFFERT)
    assert r.status_code == 200, r.text

    # La standard reservee est liberee, la suite est prise.
    assert (await reservees(chambres["standard"]), await reservees(chambres["suite"])) == (0, 1)


async def test_pas_de_surclassement_vers_une_categorie_promise(
    client, session, auth_a, chambres
):
    """La suite est libre ce soir mais reservee pour la seconde nuit : y
    surclasser un client pour deux nuits la surreserverait."""
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])
    awa = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Kofi", "last_name": "Mensah"}, headers=auth_a
        )
    ).json()
    r = await client.post(
        "/api/v1/reservations",
        json={
            "id": str(uuid7()), "guest_id": awa["id"],
            "rooms": [{
                "id": str(uuid7()), "room_type_id": chambres["suite"],
                "arrival_date": str(ARRIVAL + dt.timedelta(days=1)),
                "departure_date": str(DEPARTURE),
            }],
        },
        headers=auth_a,
    )
    assert r.status_code == 201, r.text

    for upgrade in (OFFERT, PAYANT):
        r = await _arriver(client, auth_a, res_id, line_id, chambres["501"], upgrade)
        assert r.status_code == 409, r.text
        assert "disponibilite" in r.json()["detail"]
    # Rien n'a bouge : la ligne, son tarif, la suite.
    ligne = await _ligne(session, line_id)
    assert str(ligne.room_type_id) == chambres["standard"]
    assert (ligne.booked_room_type_id, ligne.nightly_rate) == (None, 25_000)
    assert await _occupation(session, chambres["501"]) == OccupancyStatus.VACANT

    # Dans sa categorie, l'arrivee se fait ; et en cours de sejour, le meme
    # refus vaut pour le changement de chambre.
    assert (await _arriver(client, auth_a, res_id, line_id, chambres["101"])).status_code == 200
    r = await client.post(
        f"/api/v1/reservations/{res_id}/rooms/{line_id}/change-room",
        json={"room_id": chambres["501"], "upgrade": OFFERT},
        headers=auth_a,
    )
    assert r.status_code == 409, r.text
    assert await _occupation(session, chambres["101"]) == OccupancyStatus.OCCUPIED
    assert await _occupation(session, chambres["501"]) == OccupancyStatus.VACANT


async def test_une_reservation_qui_ne_croise_pas_le_sejour_ne_gene_pas(
    client, auth_a, chambres
):
    """La suite est reservee a partir du jour du depart : elle est libre sur
    toute la duree du sejour, le surclassement passe."""
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])
    kofi = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Kofi", "last_name": "Mensah"}, headers=auth_a
        )
    ).json()
    r = await client.post(
        "/api/v1/reservations",
        json={
            "id": str(uuid7()), "guest_id": kofi["id"],
            "rooms": [{
                "id": str(uuid7()), "room_type_id": chambres["suite"],
                "arrival_date": str(DEPARTURE),
                "departure_date": str(DEPARTURE + dt.timedelta(days=2)),
            }],
        },
        headers=auth_a,
    )
    assert r.status_code == 201, r.text

    r = await _arriver(client, auth_a, res_id, line_id, chambres["501"], OFFERT)

    assert r.status_code == 200, r.text
    assert r.json()["rooms"][0]["room_type_id"] == chambres["suite"]


# --- En cours de sejour ---------------------------------------------------------


def _changer(res_id, line_id) -> str:
    return f"/api/v1/reservations/{res_id}/rooms/{line_id}/change-room"


async def test_changer_de_chambre_vers_une_autre_categorie(client, session, auth_a, chambres):
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])
    assert (await _arriver(client, auth_a, res_id, line_id, chambres["101"])).status_code == 200

    # Sans `upgrade`, comme avant.
    r = await client.post(
        _changer(res_id, line_id), json={"room_id": chambres["501"]}, headers=auth_a
    )
    assert r.status_code == 422

    corps = {"room_id": chambres["501"], "upgrade": OFFERT}
    r = await client.post(_changer(res_id, line_id), json=corps, headers=auth_a)
    assert r.status_code == 200, r.text
    (ligne,) = r.json()["rooms"]
    assert ligne["room_type_id"] == chambres["suite"]
    assert ligne["booked_room_type_id"] == chambres["standard"]
    assert ligne["nightly_rate"] == 25_000
    assert await _occupation(session, chambres["101"]) == OccupancyStatus.VACANT
    assert await _occupation(session, chambres["501"]) == OccupancyStatus.OCCUPIED

    # Rejoue : le client y est deja.
    r = await client.post(_changer(res_id, line_id), json=corps, headers=auth_a)
    assert r.status_code == 200, r.text


async def test_une_nuit_deja_facturee_garde_son_prix(client, session, auth_a, chambres):
    """Surclassement payant apres la premiere nuit : elle est sur l'ardoise a
    25 000, seule la seconde passe a 60 000."""
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])
    assert (await _arriver(client, auth_a, res_id, line_id, chambres["101"])).status_code == 200
    premiere = await session.scalar(
        select(StayNight).where(
            StayNight.reservation_room_id == uuid.UUID(line_id),
            StayNight.business_date == ARRIVAL,
        )
    )
    premiere.is_posted = True
    await session.commit()

    r = await client.post(
        _changer(res_id, line_id),
        json={"room_id": chambres["501"], "upgrade": PAYANT},
        headers=auth_a,
    )

    assert r.status_code == 200, r.text
    assert r.json()["rooms"][0]["nightly_rate"] == 60_000
    assert await _nuits(session, line_id) == [25_000, 60_000]


async def test_la_categorie_reservee_survit_a_un_second_surclassement(
    client, session, hotel_a, auth_a, chambres
):
    hotel, _ = hotel_a
    vip = RoomType(hotel_id=hotel.id, code="VIP", label="VIP", default_rate=40_000)
    session.add(vip)
    await session.flush()
    r301 = Room(hotel_id=hotel.id, number="301", room_type_id=vip.id)
    session.add(r301)
    await session.commit()
    id_vip, id_301 = str(vip.id), str(r301.id)
    res_id, line_id = await _reserver(client, auth_a, chambres["standard"])
    assert (
        await _arriver(client, auth_a, res_id, line_id, id_301, OFFERT)
    ).status_code == 200

    r = await client.post(
        _changer(res_id, line_id),
        json={"room_id": chambres["501"], "upgrade": {"reason": "Climatisation en panne"}},
        headers=auth_a,
    )

    assert r.status_code == 200, r.text
    (ligne,) = r.json()["rooms"]
    assert ligne["room_type_id"] == chambres["suite"] != id_vip
    assert ligne["booked_room_type_id"] == chambres["standard"]
    assert ligne["upgrade_reason"] == "Climatisation en panne"
