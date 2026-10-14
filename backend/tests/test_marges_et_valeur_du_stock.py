"""Prix, marges et valeur du stock : des chiffres calcules a la main.

L'histoire d'une semaine au bar :

1. l'economat recoit 10 bieres a 500, puis le bar 10 bieres a 600 : le cout
   moyen est (10 x 500 + 10 x 600) / 20 = 550 ;
2. le bar vend 4 bieres a 1 500 et un plat du jour a 4 000 : recette 10 000,
   dont 4 000 sans cout connu ; cout 4 x 550 = 2 200 ; marge 6 000 - 2 200 =
   3 800, soit 63,33 % ;
3. l'economat recoit 6 bieres a 900. Il restait 16 bieres a 550 (8 800) :
   (8 800 + 5 400) / 22 = 645,45, soit 645. La marge de la semaine ne bouge
   pas -- le cout d'une vente est celui du jour de la vente ;
4. le stock vaut 16 x 645 = 10 320 a l'economat et 6 x 645 = 3 870 au bar.
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
    Outlet,
    Permission,
    Product,
    Role,
    RolePermission,
    User,
    UserRole,
)
from app.services.stock_locations import ensure_central, ensure_outlet_location

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def hotel(session, hotel_a):
    """L'economat, le bar et la piscine ; la biere (achat 500, vente 1 500),
    son article a la carte du bar, et un plat du jour qui ne se stocke pas."""
    h, _ = hotel_a
    economat = await ensure_central(session, h.id)
    bar = Outlet(hotel_id=h.id, code="BAR", label="Bar")
    piscine = Outlet(hotel_id=h.id, code="PISCINE", label="Piscine")
    session.add_all([bar, piscine])
    await session.flush()
    stock_bar = await ensure_outlet_location(session, bar)
    biere = Product(
        hotel_id=h.id, reference="BIERE", label="Biere 65 cl", unit="U",
        purchase_price=500, sale_price=1_500,
    )
    session.add(biere)
    categorie = MenuCategory(hotel_id=h.id, label="Carte", outlet_id=bar.id)
    session.add(categorie)
    await session.flush()
    article = MenuItem(
        hotel_id=h.id, code="BIERE", label="Biere", menu_category_id=categorie.id,
        price=1_500, product_id=biere.id, stock_quantity=1,
    )
    plat = MenuItem(
        hotel_id=h.id, code="PLAT", label="Plat du jour", menu_category_id=categorie.id,
        price=4_000,
    )
    session.add_all([article, plat])
    await session.commit()
    return {
        "economat": str(economat.id), "stock_bar": str(stock_bar.id),
        "bar": str(bar.id), "piscine": str(piscine.id),
        "biere": str(biere.id), "article": str(article.id), "plat": str(plat.id),
    }


async def _agent(session, hotel, employee_code: str, droits: list[str]) -> None:
    """Un agent de l'hotel avec ces droits-la, et pas un de plus."""
    role = Role(id=uuid.uuid4(), code=f"R_{employee_code}", label=employee_code, is_system=False)
    session.add(role)
    await session.flush()
    connues = {
        p.code: p
        for p in (await session.scalars(select(Permission).where(Permission.code.in_(droits)))).all()
    }
    for code in droits:
        perm = connues.get(code)
        if perm is None:
            perm = Permission(id=uuid.uuid4(), code=code, label=code, module="test")
            session.add(perm)
            await session.flush()
        session.add(RolePermission(role_id=role.id, permission_id=perm.id))
    user = User(
        id=uuid.uuid4(), hotel_id=hotel.id, employee_code=employee_code,
        first_name="Test", last_name=employee_code,
        password_hash=hash_secret("Test1234!"), is_active=True, must_change_password=False,
    )
    session.add(user)
    await session.flush()
    session.add(UserRole(user_id=user.id, role_id=role.id))
    await session.commit()


async def _entree(client, auth, produit: str, magasin: str, quantite: int, prix: int) -> dict:
    payload = {
        "id": str(uuid7()), "product_id": produit, "stock_location_id": magasin,
        "type": "IN", "quantity": quantite, "unit_cost": prix,
    }
    r = await client.post("/api/v1/stock-movements", json=payload, headers=auth)
    assert r.status_code == 201, r.text
    return payload


async def _cout_moyen(session, produit: str) -> int:
    session.expire_all()
    return (await session.get(Product, uuid.UUID(produit))).average_cost


@pytest.fixture
async def semaine(client, session, auth_a, hotel):
    """Les etapes 1 et 2 : deux livraisons, puis une soiree au bar."""
    await _entree(client, auth_a, hotel["biere"], hotel["economat"], 10, 500)
    await _entree(client, auth_a, hotel["biere"], hotel["stock_bar"], 10, 600)
    r = await client.post(
        "/api/v1/cash-sessions",
        json={"opening_float": 0, "outlet_id": hotel["bar"]},
        headers=auth_a,
    )
    assert r.status_code in (200, 201), r.text
    vente = {
        "id": str(uuid7()),
        "outlet_id": hotel["bar"],
        "items": [
            {"id": str(uuid7()), "category": "FNB", "label": "Biere", "quantity": 4,
             "unit_price": 1_500, "menu_item_id": hotel["article"]},
            {"id": str(uuid7()), "category": "FNB", "label": "Plat du jour", "quantity": 1,
             "unit_price": 4_000, "menu_item_id": hotel["plat"]},
        ],
        "payment": {"id": str(uuid7()), "method": "CASH", "amount": 10_000},
    }
    r = await client.post("/api/v1/folios/walk-in", json=vente, headers=auth_a)
    assert r.status_code == 201, r.text
    return hotel


# --- Le cout moyen pondere ------------------------------------------------------


async def test_chaque_entree_met_a_jour_le_cout_moyen(client, session, auth_a, hotel):
    # Aucune entree valorisee : le cout est le prix d'achat.
    assert await _cout_moyen(session, hotel["biere"]) == 0
    marges = (await client.get("/api/v1/accounting/product-margins", headers=auth_a)).json()
    assert marges[0]["unit_cost"] == 500

    await _entree(client, auth_a, hotel["biere"], hotel["economat"], 10, 500)
    assert await _cout_moyen(session, hotel["biere"]) == 500

    # Dans un autre magasin : le cout est celui du produit, pour tout l'hotel.
    await _entree(client, auth_a, hotel["biere"], hotel["stock_bar"], 10, 600)
    assert await _cout_moyen(session, hotel["biere"]) == 550

    # (20 x 550 + 6 x 900) / 26 = 16 400 / 26 = 630,77.
    await _entree(client, auth_a, hotel["biere"], hotel["economat"], 6, 900)
    assert await _cout_moyen(session, hotel["biere"]) == 631

    produit = (await client.get("/api/v1/products", headers=auth_a)).json()[0]
    assert produit["average_cost"] == 631
    assert produit["purchase_price"] == 500


async def test_une_entree_renvoyee_ne_se_moyenne_pas_deux_fois(client, session, auth_a, hotel):
    await _entree(client, auth_a, hotel["biere"], hotel["economat"], 10, 500)
    livraison = await _entree(client, auth_a, hotel["biere"], hotel["economat"], 10, 600)
    assert await _cout_moyen(session, hotel["biere"]) == 550

    # Renvoyee par la file : rejouee, elle donnerait (20 x 550 + 10 x 600) / 30 = 567.
    r = await client.post("/api/v1/stock-movements", json=livraison, headers=auth_a)
    assert r.status_code == 200, r.text
    assert await _cout_moyen(session, hotel["biere"]) == 550


async def test_une_entree_sans_prix_et_une_sortie_laissent_le_cout(client, session, auth_a, hotel):
    await _entree(client, auth_a, hotel["biere"], hotel["economat"], 10, 600)
    await _entree(client, auth_a, hotel["biere"], hotel["economat"], 10, 0)
    r = await client.post(
        "/api/v1/stock-movements",
        json={"product_id": hotel["biere"], "stock_location_id": hotel["economat"],
              "type": "LOSS", "quantity": 3, "unit_cost": 900},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text
    assert await _cout_moyen(session, hotel["biere"]) == 600


# --- La marge par produit -------------------------------------------------------


async def test_la_marge_d_un_produit_est_son_prix_de_vente_moins_son_cout(
    client, auth_a, semaine
):
    r = await client.get("/api/v1/accounting/product-margins", headers=auth_a)

    assert r.status_code == 200, r.text
    (biere,) = r.json()
    assert biere["purchase_price"] == 500
    assert biere["average_cost"] == 550
    assert biere["unit_cost"] == 550
    assert biere["sale_price"] == 1_500
    assert biere["margin"] == 950
    # 950 / 1 500 = 63,33 %.
    assert biere["margin_rate_bp"] == 6_333


# --- La marge par point de vente, sur une periode -------------------------------


async def test_la_marge_du_bar_sur_la_semaine(client, auth_a, semaine):
    # Sans dates : les sept dernieres journees hotelieres.
    r = await client.get(
        "/api/v1/accounting/margins", params={"outlet_id": semaine["bar"]}, headers=auth_a
    )

    assert r.status_code == 200, r.text
    rapport = r.json()
    debut, fin = dt.date.fromisoformat(rapport["date_from"]), dt.date.fromisoformat(rapport["date_to"])
    assert (fin - debut).days == 6
    (bar,) = rapport["outlets"]
    assert bar["code"] == "BAR"
    assert bar["revenue"] == 10_000
    assert bar["uncosted_revenue"] == 4_000
    assert bar["cost"] == 2_200
    assert bar["margin"] == 3_800
    # 3 800 / 6 000 = 63,33 %.
    assert bar["margin_rate_bp"] == 6_333

    par_libelle = {p["label"]: p for p in bar["products"]}
    assert par_libelle["Biere"] == {
        "product_id": semaine["biere"], "label": "Biere", "quantity": 4,
        "revenue": 6_000, "cost": 2_200, "margin": 3_800,
    }
    # Le plat du jour ne sort d'aucun stock : sa recette, pas de cout.
    assert par_libelle["Plat du jour"] == {
        "product_id": None, "label": "Plat du jour", "quantity": 1,
        "revenue": 4_000, "cost": None, "margin": None,
    }
    assert (rapport["revenue"], rapport["cost"], rapport["margin"]) == (10_000, 2_200, 3_800)


async def test_une_livraison_plus_chere_ne_change_pas_la_marge_deja_faite(
    client, session, auth_a, semaine
):
    await _entree(client, auth_a, semaine["biere"], semaine["economat"], 6, 900)
    # 16 bieres restantes a 550 (8 800) + 6 a 900 (5 400) = 14 200 pour 22.
    assert await _cout_moyen(session, semaine["biere"]) == 645

    r = await client.get(
        "/api/v1/accounting/margins", params={"outlet_id": semaine["bar"]}, headers=auth_a
    )
    (bar,) = r.json()["outlets"]
    assert (bar["cost"], bar["margin"]) == (2_200, 3_800)


async def test_les_filtres_de_periode_et_de_point_de_vente(client, auth_a, semaine):
    tous = (await client.get("/api/v1/accounting/margins", headers=auth_a)).json()
    aujourd_hui = tous["date_to"]
    par_code = {o["code"]: o for o in tous["outlets"]}
    # La piscine n'a rien vendu : elle est la, a zero.
    assert par_code["BAR"]["margin"] == 3_800
    assert (par_code["PISCINE"]["revenue"], par_code["PISCINE"]["margin"]) == (0, 0)
    assert par_code["PISCINE"]["margin_rate_bp"] is None
    assert tous["margin"] == 3_800

    # La seule journee de la vente.
    r = await client.get(
        "/api/v1/accounting/margins",
        params={"date_from": aujourd_hui, "date_to": aujourd_hui, "outlet_id": semaine["bar"]},
        headers=auth_a,
    )
    assert r.json()["outlets"][0]["margin"] == 3_800

    # La semaine d'avant : rien.
    veille = str(dt.date.fromisoformat(aujourd_hui) - dt.timedelta(days=1))
    r = await client.get(
        "/api/v1/accounting/margins",
        params={"date_from": "2000-01-01", "date_to": veille},
        headers=auth_a,
    )
    assert r.status_code == 200, r.text
    assert (r.json()["revenue"], r.json()["cost"], r.json()["margin"]) == (0, 0, 0)

    r = await client.get(
        "/api/v1/accounting/margins", params={"outlet_id": semaine["piscine"]}, headers=auth_a
    )
    assert [o["code"] for o in r.json()["outlets"]] == ["PISCINE"]
    assert r.json()["revenue"] == 0

    r = await client.get(
        "/api/v1/accounting/margins",
        params={"date_from": aujourd_hui, "date_to": veille},
        headers=auth_a,
    )
    assert r.status_code == 422

    r = await client.get(
        "/api/v1/accounting/margins", params={"outlet_id": str(uuid7())}, headers=auth_a
    )
    assert r.status_code == 404


async def test_une_ardoise_annulee_ne_compte_ni_en_recette_ni_en_cout(
    client, session, hotel_a, login, auth_a, semaine
):
    """Le client parti sans payer : ses lignes sont annulees, la marge du bar
    ne les voit plus."""
    h, _ = hotel_a
    await _agent(session, h, "GERANT_A", ["folio.charge", "tab.cancel", "cash.session"])
    gerant = {"Authorization": f"Bearer {await login(client, 'GERANT_A')}"}
    # Rien ne se sert sans le tiroir ouvert de celui qui sert.
    r = await client.post(
        "/api/v1/cash-sessions",
        json={"opening_float": 0, "outlet_id": semaine["bar"]},
        headers=gerant,
    )
    assert r.status_code in (200, 201), r.text
    ardoise = str(uuid7())
    r = await client.post(
        "/api/v1/outlet-tabs",
        json={"id": ardoise, "outlet_id": semaine["bar"], "tab_number": 1},
        headers=gerant,
    )
    assert r.status_code in (200, 201), r.text
    r = await client.post(
        f"/api/v1/folios/{ardoise}/items",
        json={"id": str(uuid7()), "category": "FNB", "label": "Biere", "quantity": 2,
              "unit_price": 1_500, "menu_item_id": semaine["article"],
              "outlet_id": semaine["bar"]},
        headers=gerant,
    )
    assert r.status_code == 201, r.text
    avant = (await client.get("/api/v1/accounting/margins", headers=auth_a)).json()
    # 6 bieres : 9 000 de recette, 6 x 550 = 3 300 de cout.
    assert (avant["revenue"], avant["cost"], avant["margin"]) == (13_000, 3_300, 5_700)

    r = await client.post(
        f"/api/v1/outlet-tabs/{ardoise}/cancel", json={"reason": "Parti sans payer"},
        headers=gerant,
    )
    assert r.status_code == 200, r.text
    apres = (await client.get("/api/v1/accounting/margins", headers=auth_a)).json()
    assert (apres["revenue"], apres["cost"], apres["margin"]) == (10_000, 2_200, 3_800)


# --- La valeur du stock ---------------------------------------------------------


async def test_la_valeur_du_stock_par_emplacement(client, auth_a, semaine):
    await _entree(client, auth_a, semaine["biere"], semaine["economat"], 6, 900)

    r = await client.get("/api/v1/accounting/stock-value", headers=auth_a)

    assert r.status_code == 200, r.text
    valeur = r.json()
    par_magasin = {m["stock_location_id"]: m for m in valeur["locations"]}
    # L'economat d'abord : 16 bieres a 645.
    assert valeur["locations"][0]["is_central"] is True
    economat = par_magasin[semaine["economat"]]
    assert economat["value"] == 10_320
    assert economat["products"] == [{
        "product_id": semaine["biere"], "reference": "BIERE", "label": "Biere 65 cl",
        "quantity": 16, "unit_cost": 645, "value": 10_320,
    }]
    # Le bar : 10 recues, 4 vendues, 6 a 645.
    bar = par_magasin[semaine["stock_bar"]]
    assert bar["outlet_id"] == semaine["bar"]
    assert bar["value"] == 3_870
    assert valeur["value"] == 14_190

    r = await client.get(
        "/api/v1/accounting/stock-value",
        params={"stock_location_id": semaine["economat"]},
        headers=auth_a,
    )
    assert [m["value"] for m in r.json()["locations"]] == [10_320]
    assert r.json()["value"] == 10_320


async def test_un_stock_negatif_vaut_zero(client, auth_a, semaine):
    """Le bar a vendu plus qu'il n'a recu : une livraison pas encore saisie,
    pas une dette. Sa valeur ne se retranche pas de celle de l'economat."""
    r = await client.post(
        "/api/v1/stock-movements",
        json={"product_id": semaine["biere"], "stock_location_id": semaine["stock_bar"],
              "type": "OUT", "quantity": 9},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text

    valeur = (await client.get("/api/v1/accounting/stock-value", headers=auth_a)).json()
    par_magasin = {m["stock_location_id"]: m for m in valeur["locations"]}
    assert par_magasin[semaine["stock_bar"]]["value"] == 0
    assert par_magasin[semaine["stock_bar"]]["products"] == []
    # 10 bieres a 550 a l'economat.
    assert valeur["value"] == 5_500


# --- Qui lit la comptabilite ----------------------------------------------------


async def test_le_comptoir_ne_lit_ni_les_marges_ni_la_valeur_du_stock(
    client, session, hotel_a, login, semaine
):
    """Lire son stock ne donne pas la marge : elle revelerait la recette d'un
    tiroir qui se compte a l'aveugle."""
    h, _ = hotel_a
    await _agent(session, h, "BARMAN_A", ["stock.read", "order.read"])
    auth = {"Authorization": f"Bearer {await login(client, 'BARMAN_A')}"}

    for route in ("margins", "product-margins", "stock-value"):
        r = await client.get(f"/api/v1/accounting/{route}", headers=auth)
        assert r.status_code == 403, route


async def test_un_autre_hotel_ne_voit_rien(client, hotel_b, login, semaine):
    auth_b = {"Authorization": f"Bearer {await login(client, 'ADMIN_B')}"}

    r = await client.get("/api/v1/accounting/margins", headers=auth_b)
    assert r.status_code == 200, r.text
    assert (r.json()["revenue"], r.json()["outlets"]) == (0, [])
    r = await client.get(
        "/api/v1/accounting/margins", params={"outlet_id": semaine["bar"]}, headers=auth_b
    )
    assert r.status_code == 404
    assert (await client.get("/api/v1/accounting/product-margins", headers=auth_b)).json() == []
    r = await client.get("/api/v1/accounting/stock-value", headers=auth_b)
    assert r.json() == {"value": 0, "locations": []}
    r = await client.get(
        "/api/v1/accounting/stock-value",
        params={"stock_location_id": semaine["economat"]},
        headers=auth_b,
    )
    assert r.status_code == 404
