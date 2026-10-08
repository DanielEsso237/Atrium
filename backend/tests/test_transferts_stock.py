"""Les mouvements de stock : sans doublon, et les transferts valides.

L'economat ravitaille le bar ; le bar peut se ravitailler a la boite de nuit.
Un transfert attend sa validation (controleur ou comptable, un seul suffit) :
le stock ne bouge qu'a ce moment-la. Et le serveur ne refuse jamais un stock
negatif -- un refus bloquerait la file d'envoi de la tablette.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.models import Outlet, Product, StockLevel
from app.services.stock_locations import ensure_central, ensure_outlet_location

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def magasins(session, hotel_a):
    """L'economat, le bar et la boite, et un produit : la biere."""
    hotel, _ = hotel_a
    economat = await ensure_central(session, hotel.id)
    bar = Outlet(hotel_id=hotel.id, code="BAR", label="Bar")
    boite = Outlet(hotel_id=hotel.id, code="BOITE", label="Boite de nuit")
    session.add_all([bar, boite])
    await session.flush()
    stock_bar = await ensure_outlet_location(session, bar)
    stock_boite = await ensure_outlet_location(session, boite)
    biere = Product(hotel_id=hotel.id, reference="BIERE", label="Biere 65 cl", unit="U")
    session.add(biere)
    await session.commit()
    return {
        "economat": str(economat.id),
        "bar": str(stock_bar.id),
        "boite": str(stock_boite.id),
        "biere": str(biere.id),
    }


async def _quantite(session, produit: str, magasin: str) -> int:
    # Relire la base, pas l'objet garde en memoire par la session.
    session.expire_all()
    level = await session.scalar(
        select(StockLevel).where(
            StockLevel.product_id == uuid.UUID(produit),
            StockLevel.stock_location_id == uuid.UUID(magasin),
        )
    )
    return level.quantity if level is not None else 0


async def _mouvement(client, auth, **corps):
    corps.setdefault("id", str(uuid7()))
    return await client.post("/api/v1/stock-movements", json=corps, headers=auth)


async def test_une_entree_a_l_economat_compte_une_seule_fois(client, session, auth_a, magasins):
    m = magasins
    corps = {"id": str(uuid7()), "product_id": m["biere"], "stock_location_id": m["economat"],
             "type": "IN", "quantity": 48, "unit_cost": 600}
    premier = await _mouvement(client, auth_a, **corps)
    renvoi = await _mouvement(client, auth_a, **corps)

    assert premier.status_code == 201, premier.text
    assert renvoi.status_code == 200
    assert await _quantite(session, m["biere"], m["economat"]) == 48


async def test_un_transfert_attend_sa_validation(client, session, auth_a, magasins):
    m = magasins
    await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["economat"],
                     type="IN", quantity=48)
    r = await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["economat"],
                         type="TRANSFER", quantity=24, counterpart_location_id=m["bar"])
    assert r.status_code == 201, r.text
    transfert = r.json()
    assert transfert["status"] == "PENDING"
    # Rien n'a bouge.
    assert await _quantite(session, m["biere"], m["bar"]) == 0

    ok = await client.post(
        f"/api/v1/stock-movements/{transfert['id']}/approve", json={}, headers=auth_a
    )
    assert ok.status_code == 200, ok.text
    assert ok.json()["status"] == "APPROVED"
    assert await _quantite(session, m["biere"], m["economat"]) == 24
    assert await _quantite(session, m["biere"], m["bar"]) == 24

    # Validation rejouee : rien ne bouge une seconde fois.
    await client.post(f"/api/v1/stock-movements/{transfert['id']}/approve", json={}, headers=auth_a)
    assert await _quantite(session, m["biere"], m["bar"]) == 24


async def test_un_point_de_vente_se_ravitaille_chez_un_autre(client, session, auth_a, magasins):
    m = magasins
    await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["boite"],
                     type="IN", quantity=10)
    r = await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["boite"],
                         type="TRANSFER", quantity=4, counterpart_location_id=m["bar"])
    await client.post(f"/api/v1/stock-movements/{r.json()['id']}/approve", json={}, headers=auth_a)

    assert await _quantite(session, m["biere"], m["boite"]) == 6
    assert await _quantite(session, m["biere"], m["bar"]) == 4


async def test_un_transfert_refuse_ne_bouge_rien(client, session, auth_a, magasins):
    m = magasins
    r = await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["economat"],
                         type="TRANSFER", quantity=5, counterpart_location_id=m["bar"])
    non = await client.post(
        f"/api/v1/stock-movements/{r.json()['id']}/reject",
        json={"note": "Le bar en a encore"}, headers=auth_a,
    )
    assert non.status_code == 200, non.text
    assert (non.json()["status"], non.json()["decision_note"]) == ("REJECTED", "Le bar en a encore")
    assert await _quantite(session, m["biere"], m["bar"]) == 0

    # Refuse puis valide : non. Le contraire non plus.
    tard = await client.post(
        f"/api/v1/stock-movements/{r.json()['id']}/approve", json={}, headers=auth_a
    )
    assert tard.status_code == 409


async def test_un_stock_peut_passer_sous_zero(client, session, auth_a, magasins):
    # Decision du 8 octobre : on vend, et l'econome est alerte. Le serveur ne
    # refuse pas, sinon la file de la tablette se bloquerait.
    m = magasins
    r = await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["bar"],
                         type="OUT", quantity=1)
    assert r.status_code == 201, r.text
    assert await _quantite(session, m["biere"], m["bar"]) == -1


async def test_un_transfert_va_d_un_magasin_a_un_autre(client, auth_a, magasins):
    m = magasins
    r = await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["bar"],
                         type="TRANSFER", quantity=1, counterpart_location_id=m["bar"])
    assert r.status_code == 422
