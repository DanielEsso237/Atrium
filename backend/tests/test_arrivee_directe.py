"""L'arrivee directe : un client sans reservation, en nuits ou en heures.

Un voyageur arrive et prend une chambre. Une requete fait tout : le client,
le dossier, l'arrivee, l'ardoise et la charge du sejour, au prix saisi.

Les chiffres : une Standard a 25 000 la nuit.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import func, select

from app.api.v1.dashboard import count_departures
from app.api.v1.stays import night_rates, stay_label
from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import (
    Guest,
    Permission,
    Reservation,
    Role,
    RolePermission,
    Room,
    RoomType,
    StayNight,
    User,
    UserRole,
)
from app.models.enums import OccupancyStatus, StayUnit
from app.services.business_day import current_business_date

URL = "/api/v1/stays/walk-in"


# --- Sans base ------------------------------------------------------------------


def test_le_libelle_de_la_charge():
    assert stay_label(StayUnit.HOURS, 3) == "Séjour 3 h"
    assert stay_label(StayUnit.NIGHTS, 1) == "Séjour 1 nuit"
    assert stay_label(StayUnit.NIGHTS, 2) == "Séjour 2 nuits"


def test_le_prix_se_repartit_sur_les_nuits_au_franc_pres():
    assert night_rates(50_000, 2) == [25_000, 25_000]
    # 50 000 / 3 = 16 666, reste 2 : la premiere nuit le prend.
    assert night_rates(50_000, 3) == [16_668, 16_666, 16_666]
    assert sum(night_rates(50_000, 3)) == 50_000
    assert night_rates(0, 2) == [0, 0]


# --- Avec base ------------------------------------------------------------------


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def chambres(session, hotel_a):
    """Deux standards a 25 000, propres et libres."""
    hotel, _ = hotel_a
    standard = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    session.add(standard)
    await session.flush()
    r101 = Room(hotel_id=hotel.id, number="101", room_type_id=standard.id)
    r102 = Room(hotel_id=hotel.id, number="102", room_type_id=standard.id)
    session.add_all([r101, r102])
    await session.commit()
    return {"standard": str(standard.id), "101": str(r101.id), "102": str(r102.id)}


def _corps(room: str, unit: str, duration: int, price: int, **extra) -> dict:
    corps = {
        "id": str(uuid7()), "line_id": str(uuid7()), "folio_id": str(uuid7()),
        "charge_id": str(uuid7()), "room_id": room,
        "unit": unit, "duration": duration, "price": price,
    }
    if "guest_id" not in extra and "guest" not in extra:
        extra["guest"] = {"id": str(uuid7()), "first_name": "Kofi", "last_name": "Mensah"}
    return {**corps, **extra}


async def _client_connu(client, auth, **fiche) -> str:
    r = await client.post(
        "/api/v1/guests",
        json={"first_name": "Awa", "last_name": "Diallo", **fiche},
        headers=auth,
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _ardoise(client, auth, folio_id: str) -> dict:
    r = await client.get(f"/api/v1/folios/{folio_id}", headers=auth)
    assert r.status_code == 200, r.text
    return r.json()


async def _compte(session, model) -> int:
    session.expire_all()
    return await session.scalar(select(func.count()).select_from(model))


async def _aujourd_hui(session, hotel_a) -> dt.date:
    """La journee hoteliere en cours : jamais la date du calendrier."""
    hotel, _ = hotel_a
    return await current_business_date(session, hotel.id)


pytestmark_db = pytest.mark.db


@pytestmark_db
async def test_trois_heures_pour_un_nouveau_client(client, session, hotel_a, auth_a, chambres):
    _, admin = hotel_a
    admin_id = str(admin.id)
    corps = _corps(chambres["101"], "HOURS", 3, 10_000)

    r = await client.post(URL, json=corps, headers=auth_a)

    assert r.status_code == 201, r.text
    dossier = r.json()
    assert dossier["id"] == corps["id"]
    assert dossier["source"] == "WALK_IN"
    assert dossier["status"] == "CHECKED_IN"
    assert dossier["guest_id"] == corps["guest"]["id"]
    assert dossier["estimated_total"] == 10_000
    assert dossier["folio_id"] == corps["folio_id"]
    (ligne,) = dossier["rooms"]
    assert ligne["id"] == corps["line_id"]
    assert ligne["room_id"] == chambres["101"]
    assert ligne["status"] == "CHECKED_IN"
    assert (ligne["is_walk_in"], ligne["stay_unit"]) == (True, "HOURS")
    # Le depart est une heure : trois heures apres l'arrivee.
    arrivee = dt.datetime.fromisoformat(ligne["checked_in_at"])
    depart = dt.datetime.fromisoformat(ligne["departure_at"])
    assert depart - arrivee == dt.timedelta(hours=3)
    # Aucune categorie n'a de tarif a l'heure : on garde qui a saisi le prix.
    assert ligne["rate_set_by"] == admin_id

    # Une seule charge, du prix saisi ; aucune nuit.
    ardoise = await _ardoise(client, auth_a, corps["folio_id"])
    (charge,) = ardoise["items"]
    assert charge["id"] == corps["charge_id"]
    assert (charge["label"], charge["category"], charge["amount"]) == ("Séjour 3 h", "ROOM", 10_000)
    assert (ardoise["charges_total"], ardoise["balance"]) == (10_000, 10_000)
    assert await _compte(session, StayNight) == 0

    chambre = await session.get(Room, uuid.UUID(chambres["101"]))
    assert chambre.occupancy_status == OccupancyStatus.OCCUPIED
    client_cree = await session.get(Guest, uuid.UUID(corps["guest"]["id"]))
    assert (client_cree.first_name, client_cree.last_name) == ("Kofi", "Mensah")
    assert client_cree.code


@pytestmark_db
async def test_deux_nuits_pour_un_client_connu_au_tarif(
    client, session, hotel_a, auth_a, chambres
):
    awa = await _client_connu(client, auth_a)
    corps = _corps(chambres["101"], "NIGHTS", 2, 50_000, guest_id=awa)

    r = await client.post(URL, json=corps, headers=auth_a)

    assert r.status_code == 201, r.text
    dossier = r.json()
    assert dossier["guest_id"] == awa
    aujourd_hui = await _aujourd_hui(session, hotel_a)
    (ligne,) = dossier["rooms"]
    assert ligne["arrival_date"] == str(aujourd_hui)
    assert ligne["departure_date"] == str(aujourd_hui + dt.timedelta(days=2))
    assert (ligne["stay_unit"], ligne["departure_at"]) == ("NIGHTS", None)
    assert ligne["nightly_rate"] == 25_000
    # 2 x 25 000 : le tarif de la categorie, personne n'a change le prix.
    assert ligne["rate_set_by"] is None

    ardoise = await _ardoise(client, auth_a, corps["folio_id"])
    (charge,) = ardoise["items"]
    assert (charge["label"], charge["amount"]) == ("Séjour 2 nuits", 50_000)
    assert ardoise["balance"] == 50_000
    # Les deux nuits sont inscrites, deja portees.
    session.expire_all()
    nuits = (await session.scalars(select(StayNight).order_by(StayNight.business_date))).all()
    assert [(n.business_date, n.rate, n.is_posted) for n in nuits] == [
        (aujourd_hui, 25_000, True),
        (aujourd_hui + dt.timedelta(days=1), 25_000, True),
    ]
    # Aucune seconde fiche pour Awa.
    assert await _compte(session, Guest) == 1


@pytestmark_db
async def test_un_prix_different_du_tarif_garde_qui_l_a_saisi(
    client, session, hotel_a, auth_a, chambres
):
    _, admin = hotel_a
    admin_id = str(admin.id)
    # 2 nuits negociees a 40 000 au lieu de 50 000.
    corps = _corps(chambres["101"], "NIGHTS", 2, 40_000)

    r = await client.post(URL, json=corps, headers=auth_a)

    assert r.status_code == 201, r.text
    (ligne,) = r.json()["rooms"]
    assert ligne["rate_set_by"] == admin_id
    assert ligne["nightly_rate"] == 20_000
    assert r.json()["estimated_total"] == 40_000
    assert (await _ardoise(client, auth_a, corps["folio_id"]))["balance"] == 40_000


@pytestmark_db
async def test_une_nuit_d_arrivee_directe_ne_se_facture_pas_une_seconde_fois(
    client, session, hotel_a, auth_a, chambres
):
    """La tablette qui porterait la nuit comme apres un check-in ordinaire
    retrouve la charge du sejour, au lieu d'en creer une seconde."""
    corps = _corps(chambres["101"], "NIGHTS", 2, 50_000)
    assert (await client.post(URL, json=corps, headers=auth_a)).status_code == 201
    aujourd_hui = await _aujourd_hui(session, hotel_a)

    r = await client.post(
        f"/api/v1/folios/{corps['folio_id']}/items",
        json={"id": str(uuid7()), "category": "ROOM", "label": "Nuitee",
              "unit_price": 25_000, "night_date": str(aujourd_hui)},
        headers=auth_a,
    )

    assert r.status_code == 200, r.text
    assert r.json()["id"] == corps["charge_id"]
    assert (await _ardoise(client, auth_a, corps["folio_id"]))["balance"] == 50_000


@pytestmark_db
async def test_chambre_occupee_refusee_et_rien_n_est_cree(client, session, auth_a, chambres):
    assert (
        await client.post(URL, json=_corps(chambres["101"], "HOURS", 2, 8_000), headers=auth_a)
    ).status_code == 201

    r = await client.post(URL, json=_corps(chambres["101"], "NIGHTS", 1, 25_000), headers=auth_a)

    assert r.status_code == 409
    # Ni dossier, ni fiche pour le second voyageur.
    assert await _compte(session, Reservation) == 1
    assert await _compte(session, Guest) == 1

    r = await client.post(URL, json=_corps(str(uuid7()), "HOURS", 2, 8_000), headers=auth_a)
    assert r.status_code == 404


@pytestmark_db
async def test_l_arrivee_directe_se_rejoue(client, session, auth_a, chambres):
    corps = _corps(chambres["101"], "NIGHTS", 2, 50_000)

    premier = await client.post(URL, json=corps, headers=auth_a)
    second = await client.post(URL, json=corps, headers=auth_a)

    # La chambre est occupee -- par ce sejour : le renvoi n'est pas refuse.
    assert (premier.status_code, second.status_code) == (201, 200)
    assert second.json()["folio_id"] == premier.json()["folio_id"] == corps["folio_id"]
    assert second.json()["rooms"] == premier.json()["rooms"]
    ardoise = await _ardoise(client, auth_a, corps["folio_id"])
    assert len(ardoise["items"]) == 1
    assert ardoise["balance"] == 50_000
    assert await _compte(session, Reservation) == 1
    assert await _compte(session, Guest) == 1
    assert await _compte(session, StayNight) == 2


@pytestmark_db
async def test_les_corps_incoherents_sont_refuses(client, auth_a, chambres):
    awa = await _client_connu(client, auth_a)
    fiche = {"first_name": "Kofi", "last_name": "Mensah"}
    base = _corps(chambres["101"], "HOURS", 3, 10_000)
    sans_client = {k: v for k, v in base.items() if k != "guest"}

    for corps in (
        sans_client,                                         # ni client, ni fiche
        {**sans_client, "guest_id": awa, "guest": fiche},    # les deux
        {**base, "duration": 0},
        {**base, "duration": 25},                            # plus d'une journee en heures
        {**base, "price": -1},
        {**base, "unit": "DAYS"},
        {**base, "folio_id": base["id"]},                    # identifiants en double
    ):
        r = await client.post(URL, json=corps, headers=auth_a)
        assert r.status_code == 422, corps

    r = await client.post(URL, json={**sans_client, "guest_id": str(uuid7())}, headers=auth_a)
    assert r.status_code == 404


@pytestmark_db
async def test_il_faut_creer_un_dossier_et_ecrire_sur_l_ardoise(
    client, session, hotel_a, login, chambres
):
    hotel, _ = hotel_a
    for code, droits in (("SANS_ARDOISE", ["reservation.create"]), ("SANS_DOSSIER", ["folio.write"])):
        role = Role(id=uuid.uuid4(), code=f"R_{code}", label=code, is_system=False)
        session.add(role)
        await session.flush()
        for droit in droits:
            perm = await session.scalar(select(Permission).where(Permission.code == droit))
            session.add(RolePermission(role_id=role.id, permission_id=perm.id))
        agent = User(
            id=uuid.uuid4(), hotel_id=hotel.id, employee_code=code,
            first_name="Test", last_name=code,
            password_hash=hash_secret("Test1234!"), is_active=True, must_change_password=False,
        )
        session.add(agent)
        await session.flush()
        session.add(UserRole(user_id=agent.id, role_id=role.id))
    await session.commit()

    for code in ("SANS_ARDOISE", "SANS_DOSSIER"):
        auth = {"Authorization": f"Bearer {await login(client, code)}"}
        r = await client.post(URL, json=_corps(chambres["101"], "HOURS", 3, 10_000), headers=auth)
        assert r.status_code == 403, code
    assert await _compte(session, Reservation) == 0


@pytestmark_db
async def test_le_plafond_du_client_vaut_aussi_a_l_arrivee_directe(client, session, auth_a, chambres):
    awa = await _client_connu(client, auth_a, credit_limit=30_000)

    r = await client.post(
        URL, json=_corps(chambres["101"], "NIGHTS", 2, 50_000, guest_id=awa), headers=auth_a
    )

    assert r.status_code == 409
    assert "Seuil" in r.json()["detail"]
    assert await _compte(session, Reservation) == 0
    chambre = await session.get(Room, uuid.UUID(chambres["101"]))
    assert chambre.occupancy_status == OccupancyStatus.VACANT

    # Sous le plafond, elle passe.
    r = await client.post(
        URL, json=_corps(chambres["101"], "NIGHTS", 1, 25_000, guest_id=awa), headers=auth_a
    )
    assert r.status_code == 201, r.text


# --- Disponibilite, plan des chambres, departs du jour --------------------------


async def _reserver(client, auth, room_type: str, arrivee: dt.date, nuits: int = 1):
    awa = await _client_connu(client, auth)
    return await client.post(
        "/api/v1/reservations",
        json={
            "id": str(uuid7()), "guest_id": awa,
            "rooms": [{
                "id": str(uuid7()), "room_type_id": room_type,
                "arrival_date": str(arrivee),
                "departure_date": str(arrivee + dt.timedelta(days=nuits)),
            }],
        },
        headers=auth,
    )


@pytestmark_db
async def test_des_nuits_ne_prennent_pas_une_chambre_promise(
    client, session, hotel_a, auth_a, chambres
):
    """Les deux standards sont reservees pour ce soir : pas de nuit en
    arrivee directe. Quelques heures, si -- le client sera parti avant."""
    aujourd_hui = await _aujourd_hui(session, hotel_a)
    for _ in range(2):
        assert (await _reserver(client, auth_a, chambres["standard"], aujourd_hui)).status_code == 201

    r = await client.post(URL, json=_corps(chambres["101"], "NIGHTS", 1, 25_000), headers=auth_a)
    assert r.status_code == 409

    r = await client.post(URL, json=_corps(chambres["101"], "HOURS", 3, 10_000), headers=auth_a)
    assert r.status_code == 201, r.text


@pytestmark_db
async def test_un_sejour_en_heures_ne_compte_pas_dans_les_nuits(
    client, session, hotel_a, auth_a, chambres
):
    aujourd_hui = await _aujourd_hui(session, hotel_a)
    assert (
        await client.post(URL, json=_corps(chambres["101"], "HOURS", 3, 10_000), headers=auth_a)
    ).status_code == 201

    async def reservees() -> int:
        r = await client.get(
            "/api/v1/reservations/availability",
            params={"room_type_id": chambres["standard"], "arrival_date": str(aujourd_hui),
                    "departure_date": str(aujourd_hui + dt.timedelta(days=1))},
            headers=auth_a,
        )
        return r.json()["booked_rooms"]

    assert await reservees() == 0
    # Les deux standards restent reservables pour ce soir.
    for _ in range(2):
        assert (await _reserver(client, auth_a, chambres["standard"], aujourd_hui)).status_code == 201

    # Des nuits, elles, comptent.
    assert await reservees() == 2


@pytestmark_db
async def test_le_plan_et_les_departs_du_jour_lisent_l_heure_de_depart(
    client, session, hotel_a, auth_a, chambres
):
    hotel, _ = hotel_a
    hotel_id = hotel.id
    aujourd_hui = await _aujourd_hui(session, hotel_a)
    assert await count_departures(session, hotel_id, aujourd_hui) == 0
    heures = _corps(chambres["101"], "HOURS", 1, 5_000)
    nuits = _corps(chambres["102"], "NIGHTS", 2, 50_000)
    for corps in (heures, nuits):
        assert (await client.post(URL, json=corps, headers=auth_a)).status_code == 201

    # Le sejour d'une heure part aujourd'hui ; celui de deux nuits, non.
    assert await count_departures(session, hotel_id, aujourd_hui) == 1
    # Dans deux jours : celui de deux nuits, et l'autre, alors en retard.
    assert await count_departures(session, hotel_id, aujourd_hui + dt.timedelta(days=2)) == 2

    fiche = (await client.get(f"/api/v1/rooms/{chambres['101']}", headers=auth_a)).json()
    assert fiche["current_stay"]["stay_unit"] == "HOURS"
    assert fiche["current_stay"]["departure_at"] is not None
    fiche = (await client.get(f"/api/v1/rooms/{chambres['102']}", headers=auth_a)).json()
    assert (fiche["current_stay"]["stay_unit"], fiche["current_stay"]["departure_at"]) == (
        "NIGHTS", None,
    )

    # Parti, il n'est plus a faire partir.
    r = await client.post(
        f"/api/v1/reservations/{heures['id']}/rooms/{heures['line_id']}/check-out",
        headers=auth_a,
    )
    assert r.status_code == 200, r.text
    assert await count_departures(session, hotel_id, aujourd_hui) == 0


@pytestmark_db
async def test_le_client_d_une_arrivee_directe_repart_comme_un_autre(
    client, session, auth_a, chambres
):
    corps = _corps(chambres["101"], "HOURS", 3, 10_000)
    assert (await client.post(URL, json=corps, headers=auth_a)).status_code == 201

    r = await client.post(
        f"/api/v1/reservations/{corps['id']}/rooms/{corps['line_id']}/check-out", headers=auth_a
    )

    assert r.status_code == 200, r.text
    assert r.json()["status"] == "CHECKED_OUT"
    session.expire_all()
    chambre = await session.get(Room, uuid.UUID(chambres["101"]))
    assert chambre.occupancy_status == OccupancyStatus.VACANT
