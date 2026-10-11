"""La reception est la caisse centrale : le versement du soir.

Chaque point de vente tient son tiroir pendant le service. Le soir, son
agent declare ce qu'il remet -- c'est la fermeture de sa caisse -- et la
reception confirme ce qu'elle recoit. Trois chiffres restent : l'attendu
(le fond de caisse et les ventes en especes), le declare et le recu.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.core.security import hash_secret
from app.db.seed import HOTEL, OUTLET_RECEPTION, OUTLET_RECEPTION_CODE, seed
from app.models import Permission, Role, RolePermission, StockLocation, User, UserRole
from app.models.restaurant import Outlet
from app.services.outlets import RECEPTION_OUTLET_CODE

pytestmark = pytest.mark.db

COMPTOIR = ["order.create", "folio.charge", "cash.session"]
RECEPTION = ["cash.session", "cash.central", "folio.read"]


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
        first_name="Ines",
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
async def bar(session, hotel_a):
    hotel, _ = hotel_a
    outlet = Outlet(hotel_id=hotel.id, code="BAR", label="Bar", allows_room_charge=True)
    session.add(outlet)
    await session.commit()
    return str(outlet.id)


@pytest.fixture
async def auth_bar(client, session, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(session, hotel, "BARMAN", COMPTOIR)
    return {"Authorization": f"Bearer {await login(client, 'BARMAN')}"}


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def auth_reception(client, session, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(session, hotel, "RECEP", RECEPTION)
    return {"Authorization": f"Bearer {await login(client, 'RECEP')}"}


def _vente(bar, montant, moyen="CASH"):
    return {
        "id": str(uuid7()),
        "outlet_id": bar,
        "items": [{"id": str(uuid7()), "category": "FNB", "label": "Biere", "unit_price": montant}],
        "payment": {"id": str(uuid7()), "method": moyen, "amount": montant},
    }


async def _ouvrir(client, auth, fond=0, **corps):
    r = await client.post(
        "/api/v1/cash-sessions", json={"opening_float": fond, **corps}, headers=auth
    )
    assert r.status_code in (200, 201), r.text
    return r.json()


async def _verser(client, auth, caisse, montant):
    r = await client.post(
        f"/api/v1/cash-sessions/{caisse['id']}/close",
        json={"counted_amount": montant},
        headers=auth,
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _soiree_du_bar(client, bar, auth_bar, *, verse):
    """Le bar ouvre a 5 000, vend 12 000 en especes et 4 000 en mobile, verse."""
    caisse = await _ouvrir(client, auth_bar, fond=5_000, outlet_id=bar)
    for montant, moyen in ((7_000, "CASH"), (5_000, "CASH"), (4_000, "MOBILE_MONEY")):
        r = await client.post(
            "/api/v1/folios/walk-in", json=_vente(bar, montant, moyen), headers=auth_bar
        )
        assert r.status_code == 201, r.text
    return await _verser(client, auth_bar, caisse, verse)


# --- La caisse d'un point de vente ----------------------------------------------


def test_le_seed_et_le_serveur_parlent_du_meme_code():
    assert OUTLET_RECEPTION_CODE == RECEPTION_OUTLET_CODE == "RECEPTION"


async def test_la_caisse_garde_l_identifiant_de_la_tablette(client, bar, auth_bar):
    """Sans lui, la fermeture envoyee ensuite ne retrouvait pas la caisse."""
    mien = str(uuid7())
    caisse = await _ouvrir(client, auth_bar, id=mien, outlet_id=bar)

    assert caisse["id"] == mien
    assert caisse["outlet_id"] == bar
    ferme = await _verser(client, auth_bar, caisse, 0)
    assert ferme["status"] == "CLOSED"


async def test_renvoyer_une_ouverture_deja_fermee_ne_rouvre_rien(client, bar, auth_bar):
    mien = str(uuid7())
    caisse = await _ouvrir(client, auth_bar, id=mien, outlet_id=bar)
    await _verser(client, auth_bar, caisse, 0)

    renvoi = await _ouvrir(client, auth_bar, id=mien, outlet_id=bar)

    assert renvoi["id"] == mien
    assert renvoi["status"] == "CLOSED"
    r = await client.get("/api/v1/cash-sessions/current", headers=auth_bar)
    assert r.status_code == 404


async def test_la_reception_qui_sert_au_bar_ouvre_le_tiroir_du_bar(
    client, bar, auth_reception
):
    """Un tiroir par point de vente, quel que soit l'agent (decision du 11
    octobre) : la recette du bar reste celle du bar, et la caisse centrale
    reste a part."""
    centrale = await _ouvrir(client, auth_reception)
    du_bar = await _ouvrir(client, auth_reception, outlet_id=bar)

    assert centrale["outlet_id"] is None
    assert du_bar["outlet_id"] == bar
    assert du_bar["id"] != centrale["id"]


async def test_deux_tiroirs_s_ouvrent_et_se_ferment_independamment(
    client, session, hotel_a, bar, auth_bar
):
    """Paul tient le bar et le bar piscine ; il ferme la piscine a 22 h sans
    fermer le bar, et chaque vente tombe dans le tiroir de son point de vente."""
    hotel, _ = hotel_a
    piscine = Outlet(hotel_id=hotel.id, code="PISCINE", label="Bar piscine")
    session.add(piscine)
    await session.commit()
    au_bar = await _ouvrir(client, auth_bar, fond=10_000, outlet_id=bar)
    a_la_piscine = await _ouvrir(client, auth_bar, fond=5_000, outlet_id=str(piscine.id))
    assert au_bar["id"] != a_la_piscine["id"]
    # Rouvrir le bar rend le meme tiroir, sans en ouvrir un troisieme.
    assert (await _ouvrir(client, auth_bar, outlet_id=bar))["id"] == au_bar["id"]

    for outlet, montant in ((bar, 3_000), (str(piscine.id), 2_000)):
        r = await client.post(
            "/api/v1/folios/walk-in", json=_vente(outlet, montant), headers=auth_bar
        )
        assert r.status_code == 201, r.text

    piscine_fermee = await _verser(client, auth_bar, a_la_piscine, 7_000)
    assert piscine_fermee["expected_amount"] == 7_000  # 5 000 + 2 000
    assert piscine_fermee["variance"] == 0
    r = await client.get(
        "/api/v1/cash-sessions/current", params={"outlet_id": bar}, headers=auth_bar
    )
    assert r.status_code == 200
    assert r.json()["expected_amount"] == 13_000  # 10 000 + 3 000, sans la piscine


async def test_sans_le_tiroir_de_ce_point_de_vente_pas_de_vente(
    client, session, hotel_a, bar, auth_bar
):
    """Le tiroir du bar ouvert ne suffit pas a vendre a la piscine."""
    hotel, _ = hotel_a
    piscine = Outlet(hotel_id=hotel.id, code="PISCINE", label="Bar piscine")
    session.add(piscine)
    await session.commit()
    await _ouvrir(client, auth_bar, outlet_id=bar)

    r = await client.post(
        "/api/v1/folios/walk-in", json=_vente(str(piscine.id), 2_000), headers=auth_bar
    )
    assert r.status_code == 409
    assert "caisse" in r.json()["detail"]


async def test_un_point_de_vente_inconnu_n_empeche_pas_d_ouvrir(client, auth_bar):
    """Un refus bloquerait la file de la tablette, et les ventes derriere."""
    caisse = await _ouvrir(client, auth_bar, outlet_id=str(uuid7()))

    assert caisse["status"] == "OPEN"
    assert caisse["outlet_id"] is None


# --- Le versement ---------------------------------------------------------------


async def test_le_versement_ferme_la_caisse_et_constate_l_ecart(client, bar, auth_bar):
    verse = await _soiree_du_bar(client, bar, auth_bar, verse=16_000)

    # Attendu : 5 000 de fond et 12 000 d'especes. Le mobile ne passe pas par
    # le tiroir.
    assert verse["status"] == "CLOSED"
    assert verse["expected_amount"] == 17_000
    assert verse["counted_amount"] == 16_000
    assert verse["variance"] == -1_000
    assert verse["received_amount"] is None


async def test_la_reception_confirme_ce_qu_elle_recoit(
    client, bar, auth_bar, auth_reception
):
    verse = await _soiree_du_bar(client, bar, auth_bar, verse=17_000)
    centrale = await _ouvrir(client, auth_reception, fond=10_000)

    r = await client.post(
        f"/api/v1/cash-sessions/{verse['id']}/receive",
        json={"received_amount": 16_500},
        headers=auth_reception,
    )

    assert r.status_code == 200, r.text
    recu = r.json()
    assert recu["received_amount"] == 16_500
    assert recu["received_session_id"] == centrale["id"]
    assert recu["received_at"] is not None
    # Le declare et l'attendu ne bougent pas : c'est leur comparaison avec le
    # recu qui dit ou l'argent s'est perdu.
    assert recu["counted_amount"] == 17_000
    assert recu["expected_amount"] == 17_000


async def test_le_versement_recu_entre_dans_la_caisse_centrale(
    client, bar, auth_bar, auth_reception
):
    verse = await _soiree_du_bar(client, bar, auth_bar, verse=17_000)
    centrale = await _ouvrir(client, auth_reception, fond=10_000)
    await client.post(
        f"/api/v1/cash-sessions/{verse['id']}/receive",
        json={"received_amount": 17_000},
        headers=auth_reception,
    )

    r = await client.get("/api/v1/cash-sessions/current", headers=auth_reception)
    assert r.json()["expected_amount"] == 27_000

    ferme = await _verser(client, auth_reception, centrale, 27_000)
    assert ferme["variance"] == 0


async def test_confirmer_deux_fois_ne_compte_qu_une_fois(
    client, bar, auth_bar, auth_reception
):
    verse = await _soiree_du_bar(client, bar, auth_bar, verse=17_000)
    await _ouvrir(client, auth_reception)
    chemin = f"/api/v1/cash-sessions/{verse['id']}/receive"
    await client.post(chemin, json={"received_amount": 17_000}, headers=auth_reception)

    r = await client.post(chemin, json={"received_amount": 99_000}, headers=auth_reception)

    # Un renvoi de la tablette : le premier montant confirme fait foi.
    assert r.status_code == 200
    assert r.json()["received_amount"] == 17_000
    r = await client.get("/api/v1/cash-sessions/current", headers=auth_reception)
    assert r.json()["expected_amount"] == 17_000


async def test_on_ne_confirme_pas_un_versement_pas_encore_declare(
    client, bar, auth_bar, auth_reception
):
    caisse = await _ouvrir(client, auth_bar, outlet_id=bar)

    r = await client.post(
        f"/api/v1/cash-sessions/{caisse['id']}/receive",
        json={"received_amount": 0},
        headers=auth_reception,
    )

    assert r.status_code == 409


async def test_la_caisse_centrale_ne_se_verse_pas(client, auth_reception, auth_a):
    centrale = await _ouvrir(client, auth_reception)
    await _verser(client, auth_reception, centrale, 0)

    r = await client.post(
        f"/api/v1/cash-sessions/{centrale['id']}/receive",
        json={"received_amount": 0},
        headers=auth_a,
    )

    assert r.status_code == 409


async def test_le_point_de_vente_ne_confirme_pas_son_propre_versement(
    client, bar, auth_bar
):
    verse = await _soiree_du_bar(client, bar, auth_bar, verse=17_000)

    r = await client.post(
        f"/api/v1/cash-sessions/{verse['id']}/receive",
        json={"received_amount": 17_000},
        headers=auth_bar,
    )

    assert r.status_code == 403


async def test_le_versement_d_un_autre_hotel_reste_introuvable(
    client, bar, auth_bar, hotel_b, login
):
    verse = await _soiree_du_bar(client, bar, auth_bar, verse=17_000)
    auth_b = {"Authorization": f"Bearer {await login(client, 'ADMIN_B')}"}

    r = await client.post(
        f"/api/v1/cash-sessions/{verse['id']}/receive",
        json={"received_amount": 17_000},
        headers=auth_b,
    )

    assert r.status_code == 404


# --- Le rapport du soir ---------------------------------------------------------


async def test_la_reception_voit_les_caisses_de_tous_les_points_de_vente(
    client, bar, auth_bar, auth_reception
):
    verse = await _soiree_du_bar(client, bar, auth_bar, verse=17_000)
    centrale = await _ouvrir(client, auth_reception)

    r = await client.get(
        "/api/v1/cash-sessions", params={"since": "2020-01-01"}, headers=auth_reception
    )

    assert r.status_code == 200, r.text
    assert {c["id"] for c in r.json()} == {verse["id"], centrale["id"]}


async def test_un_point_de_vente_ne_voit_que_sa_caisse(
    client, bar, auth_bar, auth_reception
):
    verse = await _soiree_du_bar(client, bar, auth_bar, verse=17_000)
    await _ouvrir(client, auth_reception)

    r = await client.get(
        "/api/v1/cash-sessions", params={"since": "2020-01-01"}, headers=auth_bar
    )

    assert [c["id"] for c in r.json()] == [verse["id"]]


async def test_un_versement_en_attente_descend_quelle_que_soit_son_anciennete(
    client, bar, auth_bar, auth_reception
):
    """De l'argent pas encore recu n'est pas de l'historique."""
    verse = await _soiree_du_bar(client, bar, auth_bar, verse=17_000)

    r = await client.get(
        "/api/v1/cash-sessions", params={"since": "2999-01-01"}, headers=auth_reception
    )
    assert [c["id"] for c in r.json()] == [verse["id"]]

    await client.post(
        f"/api/v1/cash-sessions/{verse['id']}/receive",
        json={"received_amount": 17_000},
        headers=auth_reception,
    )
    r = await client.get(
        "/api/v1/cash-sessions", params={"since": "2999-01-01"}, headers=auth_reception
    )
    assert r.json() == []


# --- La reception, point de vente -----------------------------------------------


async def test_le_seed_cree_le_point_de_vente_reception_et_son_magasin(session):
    await seed(session)
    await seed(session)

    outlet = await session.get(Outlet, OUTLET_RECEPTION)
    assert outlet is not None
    assert outlet.hotel_id == HOTEL
    assert outlet.code == RECEPTION_OUTLET_CODE
    magasins = (
        await session.scalars(
            select(StockLocation).where(StockLocation.outlet_id == OUTLET_RECEPTION)
        )
    ).all()
    assert len(magasins) == 1


async def test_on_ne_desactive_pas_le_point_de_vente_reception(client, auth_a, hotel_a, session):
    hotel, _ = hotel_a
    outlet = Outlet(hotel_id=hotel.id, code=RECEPTION_OUTLET_CODE, label="Réception")
    session.add(outlet)
    await session.commit()

    r = await client.patch(
        f"/api/v1/outlets/{outlet.id}", json={"is_active": False}, headers=auth_a
    )
    assert r.status_code == 409, r.text
    r = await client.patch(
        f"/api/v1/outlets/{outlet.id}", json={"label": "Accueil"}, headers=auth_a
    )
    assert r.status_code == 200, r.text
