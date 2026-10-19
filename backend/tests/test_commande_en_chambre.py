"""La commande en chambre : la reception commande, le point de vente livre (F2.6).

Le client appelle la reception depuis sa chambre ; elle commande au bar, qui
prend la commande en charge et la monte. A la livraison, les lignes passent
sur l'ardoise du sejour, au nom du bar.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import (
    MenuCategory,
    MenuItem,
    Permission,
    Role,
    RolePermission,
    Room,
    RoomType,
    User,
    UserOutlet,
    UserRole,
)
from app.models.restaurant import Outlet

pytestmark = pytest.mark.db

RECEPTION = ["room_order.create", "order.read", "restaurant.read", "folio.charge"]
COMPTOIR = ["order.read", "order.manage", "folio.charge", "cash.session"]


async def _agent(session, hotel, code, permissions, outlets=()):
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
    for outlet in outlets:
        session.add(UserOutlet(user_id=agent.id, outlet_id=uuid.UUID(outlet)))
    await session.commit()


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def carte(session, hotel_a):
    """Le bar et le restaurant, chacun sa carte ; rend leurs ids et articles."""
    hotel, _ = hotel_a
    bar = Outlet(hotel_id=hotel.id, code="BAR", label="Bar", allows_room_charge=True)
    resto = Outlet(hotel_id=hotel.id, code="RESTO", label="Restaurant", allows_room_charge=True)
    session.add_all([bar, resto])
    await session.flush()
    cat_bar = MenuCategory(hotel_id=hotel.id, outlet_id=bar.id, label="Boissons")
    cat_resto = MenuCategory(hotel_id=hotel.id, outlet_id=resto.id, label="Plats")
    session.add_all([cat_bar, cat_resto])
    await session.flush()
    biere = MenuItem(
        hotel_id=hotel.id, code="BIERE", label="Biere", menu_category_id=cat_bar.id,
        price=1_500, tax_rate=18,
    )
    jus = MenuItem(
        hotel_id=hotel.id, code="JUS", label="Jus", menu_category_id=cat_bar.id, price=800,
    )
    poulet = MenuItem(
        hotel_id=hotel.id, code="POULET", label="Poulet", menu_category_id=cat_resto.id,
        price=6_000,
    )
    session.add_all([biere, jus, poulet])
    await session.commit()
    return {
        "bar": str(bar.id),
        "resto": str(resto.id),
        "biere": str(biere.id),
        "jus": str(jus.id),
        "poulet": str(poulet.id),
    }


@pytest.fixture
async def agents(client, session, hotel_a, login, carte):
    hotel, _ = hotel_a
    await _agent(session, hotel, "RECEP", RECEPTION)
    await _agent(session, hotel, "BARMAN", COMPTOIR, [carte["bar"]])
    await _agent(session, hotel, "BARMAN2", COMPTOIR, [carte["bar"]])
    await _agent(session, hotel, "SERVEUR", COMPTOIR, [carte["resto"]])
    await _agent(session, hotel, "RESPONSABLE", ["folio.override_limit"])
    return {
        code: {"Authorization": f"Bearer {await login(client, code)}"}
        for code in ("RECEP", "BARMAN", "BARMAN2", "SERVEUR")
    } | {
        "RESPONSABLE_ID": str(
            await session.scalar(select(User.id).where(User.employee_code == "RESPONSABLE"))
        )
    }


@pytest.fixture
async def sejour(client, session, hotel_a, auth_a):
    """Awa Diallo en 101, plafond 10 000 ; rend (dossier, ligne, ardoise)."""
    hotel, _ = hotel_a
    room_type = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number="101", room_type_id=room_type.id)
    session.add(room)
    await session.commit()
    r = await client.post(
        "/api/v1/guests",
        json={"first_name": "Awa", "last_name": "Diallo", "credit_limit": 10_000},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text
    res_id, line_id, folio_id = str(uuid7()), str(uuid7()), str(uuid7())
    r = await client.post(
        "/api/v1/reservations",
        json={
            "id": res_id,
            "guest_id": r.json()["id"],
            "rooms": [
                {
                    "id": line_id,
                    "room_type_id": str(room_type.id),
                    "arrival_date": str(dt.date(2030, 3, 10)),
                    "departure_date": str(dt.date(2030, 3, 11)),
                }
            ],
        },
        headers=auth_a,
    )
    assert r.status_code == 201, r.text
    r = await client.post(
        f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in",
        json={"room_id": str(room.id), "folio_id": folio_id},
        headers=auth_a,
    )
    assert r.status_code == 200, r.text
    return res_id, line_id, folio_id


async def _ouvrir_caisse(client, auth, outlet):
    r = await client.post(
        "/api/v1/cash-sessions", json={"opening_float": 0, "outlet_id": outlet}, headers=auth
    )
    assert r.status_code in (200, 201), r.text
    return r.json()["id"]


def _corps(carte, folio, lignes=(("biere", 2),), outlet="bar", **extra):
    return {
        "id": str(uuid7()),
        "outlet_id": carte[outlet],
        "folio_id": folio,
        "items": [
            {"id": str(uuid7()), "menu_item_id": carte[article], "quantity": quantite}
            for article, quantite in lignes
        ],
        **extra,
    }


async def _commander(client, agents, corps):
    return await client.post("/api/v1/room-orders", json=corps, headers=agents["RECEP"])


# --- Commander -------------------------------------------------------------------


async def test_la_reception_commande_et_le_renvoi_ne_double_rien(
    client, agents, carte, sejour
):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    corps = _corps(carte, folio, lignes=(("biere", 2), ("jus", 1)))

    premiere = await _commander(client, agents, corps)
    seconde = await _commander(client, agents, corps)

    assert premiere.status_code == 201, premiere.text
    commande = premiere.json()
    assert commande["status"] == "SENT"
    assert commande["folio_id"] == folio
    assert commande["total"] == 2 * 1_500 + 800
    assert commande["room_id"] is not None
    assert [i["id"] for i in commande["items"]] == [i["id"] for i in corps["items"]]
    assert seconde.status_code == 200
    assert seconde.json()["number"] == commande["number"]


async def test_pas_de_commande_vers_un_point_de_vente_ferme(client, agents, carte, sejour):
    _, _, folio = sejour

    r = await _commander(client, agents, _corps(carte, folio))

    assert r.status_code == 409
    assert "ferme" in r.json()["detail"]


async def test_un_article_d_une_autre_carte_est_refuse(client, agents, carte, sejour):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])

    r = await _commander(client, agents, _corps(carte, folio, lignes=(("poulet", 1),)))

    assert r.status_code == 422


async def test_le_comptoir_ne_commande_pas_pour_une_chambre(client, agents, carte, sejour):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])

    r = await client.post(
        "/api/v1/room-orders", json=_corps(carte, folio), headers=agents["BARMAN"]
    )

    assert r.status_code == 403


async def test_le_plafond_compte_les_commandes_en_route(client, agents, carte, sejour):
    """Plafond 10 000 : 6 000 commandes, puis 6 000 encore -- la seconde depasse."""
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    r = await _commander(client, agents, _corps(carte, folio, lignes=(("biere", 4),)))
    assert r.status_code == 201, r.text

    refusee = await _commander(client, agents, _corps(carte, folio, lignes=(("biere", 4),)))
    autorisee = await _commander(
        client,
        agents,
        _corps(
            carte, folio, lignes=(("biere", 4),), override_by=agents["RESPONSABLE_ID"]
        ),
    )

    assert refusee.status_code == 409
    assert "Seuil depasse" in refusee.json()["detail"]
    assert autorisee.status_code == 201, autorisee.text
    assert autorisee.json()["override_by"] == agents["RESPONSABLE_ID"]


# --- La descente -------------------------------------------------------------------


async def test_chaque_point_de_vente_voit_les_siennes(client, agents, carte, sejour):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    commande = (await _commander(client, agents, _corps(carte, folio))).json()

    bar = await client.get("/api/v1/room-orders", headers=agents["BARMAN"])
    resto = await client.get("/api/v1/room-orders", headers=agents["SERVEUR"])
    reception = await client.get("/api/v1/room-orders", headers=agents["RECEP"])

    assert [c["id"] for c in bar.json()] == [commande["id"]]
    assert resto.json() == []
    assert [c["id"] for c in reception.json()] == [commande["id"]]


async def test_une_commande_livree_redescend_sur_la_fenetre(client, agents, carte, sejour):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    commande = (await _commander(client, agents, _corps(carte, folio))).json()
    await client.post(
        f"/api/v1/room-orders/{commande['id']}/deliver", headers=agents["BARMAN"]
    )

    en_cours = await client.get("/api/v1/room-orders", headers=agents["BARMAN"])
    fenetre = await client.get(
        "/api/v1/room-orders?since=2000-01-01", headers=agents["BARMAN"]
    )

    assert en_cours.json() == []
    assert [c["status"] for c in fenetre.json()] == ["SERVED"]


# --- Prendre en charge, livrer ---------------------------------------------------------


async def test_le_bar_prend_en_charge_puis_livre_sur_l_ardoise(
    client, agents, carte, sejour, auth_a
):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    corps = _corps(carte, folio, lignes=(("biere", 2), ("jus", 1)))
    commande = (await _commander(client, agents, corps)).json()

    prise = await client.post(
        f"/api/v1/room-orders/{commande['id']}/accept", headers=agents["BARMAN"]
    )
    livree = await client.post(
        f"/api/v1/room-orders/{commande['id']}/deliver", headers=agents["BARMAN"]
    )
    renvoi = await client.post(
        f"/api/v1/room-orders/{commande['id']}/deliver", headers=agents["BARMAN"]
    )

    assert prise.status_code == 200, prise.text
    assert prise.json()["status"] == "IN_PREP"
    assert prise.json()["taken_by"] is not None
    assert livree.status_code == 200, livree.text
    assert livree.json()["status"] == "SERVED"
    assert renvoi.status_code == 200
    ardoise = (await client.get(f"/api/v1/folios/{folio}", headers=auth_a)).json()
    # Une ligne d'ardoise par ligne de commande, sous le meme id, au nom du bar.
    lignes = {i["id"]: i for i in ardoise["items"]}
    assert set(lignes) == {i["id"] for i in corps["items"]}
    assert {i["source_id"] for i in lignes.values()} == {carte["bar"]}
    assert ardoise["balance"] == 2 * 1_500 + 800


async def test_le_client_paie_a_la_livraison(client, agents, carte, sejour, session, auth_a):
    """Decision du client, 18 octobre : a la livraison, il paie maintenant ou
    laisse sur l'ardoise. Paye, la commande est sur l'ardoise et soldee : le
    total dans le tiroir du bar, rien de plus a devoir."""
    from app.models import Payment

    _, _, folio = sejour
    caisse = await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    corps = _corps(carte, folio, lignes=(("biere", 2), ("jus", 1)))
    commande = (await _commander(client, agents, corps)).json()
    avant = (await client.get(f"/api/v1/folios/{folio}", headers=auth_a)).json()
    paiement = {"id": str(uuid7()), "method": "CASH", "amount": 2 * 1_500 + 800}

    livree = await client.post(
        f"/api/v1/room-orders/{commande['id']}/deliver",
        json={"payment": paiement},
        headers=agents["BARMAN"],
    )
    renvoi = await client.post(
        f"/api/v1/room-orders/{commande['id']}/deliver",
        json={"payment": paiement},
        headers=agents["BARMAN"],
    )

    assert livree.status_code == 200, livree.text
    assert livree.json()["status"] == "SERVED"
    assert renvoi.status_code == 200
    apres = (await client.get(f"/api/v1/folios/{folio}", headers=auth_a)).json()
    assert apres["charges_total"] == avant["charges_total"] + 3_800
    assert apres["payments_total"] == avant["payments_total"] + 3_800
    assert apres["balance"] == avant["balance"]
    # Un seul paiement, renvoi compris, dans le tiroir du bar de celui qui livre.
    paiements = (
        await session.scalars(select(Payment).where(Payment.id == uuid.UUID(paiement["id"])))
    ).all()
    assert len(paiements) == 1
    assert str(paiements[0].cash_session_id) == caisse
    assert str(paiements[0].folio_id) == folio


async def test_le_paiement_a_la_livraison_couvre_la_commande(client, agents, carte, sejour):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    commande = (await _commander(client, agents, _corps(carte, folio))).json()

    r = await client.post(
        f"/api/v1/room-orders/{commande['id']}/deliver",
        json={"payment": {"method": "CASH", "amount": 5_000}},
        headers=agents["BARMAN"],
    )

    assert r.status_code == 409
    assert "couvrir" in r.json()["detail"]
    # Rien n'est livre : la commande attend toujours.
    liste = (await client.get("/api/v1/room-orders", headers=agents["RECEP"])).json()
    assert {c["id"]: c["status"] for c in liste}[commande["id"]] == "SENT"


async def test_le_bar_ne_livre_pas_sans_sa_caisse(client, agents, carte, sejour):
    """Un collegue a ouvert le bar ; celui qui livre n'a pas son tiroir."""
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    commande = (await _commander(client, agents, _corps(carte, folio))).json()

    r = await client.post(
        f"/api/v1/room-orders/{commande['id']}/deliver", headers=agents["BARMAN2"]
    )

    assert r.status_code == 409
    assert "caisse" in r.json()["detail"]


async def test_un_autre_point_de_vente_n_y_touche_pas(client, agents, carte, sejour):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    commande = (await _commander(client, agents, _corps(carte, folio))).json()

    prise = await client.post(
        f"/api/v1/room-orders/{commande['id']}/accept", headers=agents["SERVEUR"]
    )
    annulee = await client.post(
        f"/api/v1/room-orders/{commande['id']}/cancel",
        json={"reason": "Pas chez nous"},
        headers=agents["SERVEUR"],
    )

    assert prise.status_code == 403
    assert annulee.status_code == 403


# --- Annuler ------------------------------------------------------------------------------


async def test_le_client_se_ravise(client, agents, carte, sejour, auth_a):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    commande = (await _commander(client, agents, _corps(carte, folio))).json()

    r = await client.post(
        f"/api/v1/room-orders/{commande['id']}/cancel",
        json={"reason": "Le client se ravise"},
        headers=agents["RECEP"],
    )
    renvoi = await client.post(
        f"/api/v1/room-orders/{commande['id']}/cancel",
        json={"reason": "Le client se ravise"},
        headers=agents["RECEP"],
    )
    livree = await client.post(
        f"/api/v1/room-orders/{commande['id']}/deliver", headers=agents["BARMAN"]
    )

    assert r.status_code == 200, r.text
    assert r.json()["status"] == "CANCELLED"
    assert r.json()["cancel_reason"] == "Le client se ravise"
    assert renvoi.status_code == 200
    assert livree.status_code == 409
    ardoise = (await client.get(f"/api/v1/folios/{folio}", headers=auth_a)).json()
    assert ardoise["items"] == []


async def test_une_commande_livree_ne_s_annule_plus(client, agents, carte, sejour):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    commande = (await _commander(client, agents, _corps(carte, folio))).json()
    await client.post(
        f"/api/v1/room-orders/{commande['id']}/deliver", headers=agents["BARMAN"]
    )

    r = await client.post(
        f"/api/v1/room-orders/{commande['id']}/cancel",
        json={"reason": "Trop tard"},
        headers=agents["RECEP"],
    )

    assert r.status_code == 409


# --- Le client ne part pas avec un plateau en route ---------------------------------------


async def test_pas_de_depart_tant_qu_une_commande_est_en_route(
    client, agents, carte, sejour, auth_a
):
    res_id, line_id, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    commande = (await _commander(client, agents, _corps(carte, folio))).json()
    depart = f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-out"

    refuse = await client.post(depart, headers=auth_a)
    await client.post(
        f"/api/v1/room-orders/{commande['id']}/cancel",
        json={"reason": "Le client part"},
        headers=agents["RECEP"],
    )
    accepte = await client.post(depart, headers=auth_a)

    assert refuse.status_code == 409
    assert "commande" in refuse.json()["detail"]
    assert accepte.status_code == 200, accepte.text


async def test_l_ardoise_ne_se_clot_pas_sous_une_commande_en_route(
    client, agents, carte, sejour, auth_a
):
    _, _, folio = sejour
    await _ouvrir_caisse(client, agents["BARMAN"], carte["bar"])
    await _commander(client, agents, _corps(carte, folio))

    r = await client.post(f"/api/v1/folios/{folio}/close", headers=auth_a)

    assert r.status_code == 409
    assert "commande" in r.json()["detail"]
