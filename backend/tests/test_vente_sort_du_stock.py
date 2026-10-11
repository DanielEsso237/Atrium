"""Une vente fait sortir le stock du point de vente.

La biere vendue au bar quitte le stock du bar, qu'elle soit portee sur une
chambre ou payee par un client de passage. Un renvoi ne la fait pas sortir
deux fois ; un article qui ne se stocke pas (plat du jour) ne touche a rien ;
et le stock peut passer sous zero (decision du 8 octobre).
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.models import MenuCategory, MenuItem, Outlet, Product, Room, RoomType, StockLevel
from app.services.stock_locations import ensure_outlet_location

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def bar(session, hotel_a):
    """Le bar, son magasin, une biere en stock (relie a l'article « Biere ») et
    un plat du jour qui ne se stocke pas."""
    hotel, _ = hotel_a
    outlet = Outlet(hotel_id=hotel.id, code="BAR", label="Bar")
    session.add(outlet)
    await session.flush()
    magasin = await ensure_outlet_location(session, outlet)
    biere = Product(hotel_id=hotel.id, reference="BIERE", label="Biere 65 cl", unit="U")
    session.add(biere)
    await session.flush()
    session.add(StockLevel(product_id=biere.id, stock_location_id=magasin.id, quantity=10))
    categorie = MenuCategory(hotel_id=hotel.id, label="Boissons", outlet_id=outlet.id)
    session.add(categorie)
    await session.flush()
    article = MenuItem(
        hotel_id=hotel.id, code="BIERE", label="Biere", menu_category_id=categorie.id,
        price=1_500, product_id=biere.id, stock_quantity=1,
    )
    plat = MenuItem(
        hotel_id=hotel.id, code="PLAT", label="Plat du jour", menu_category_id=categorie.id,
        price=4_000,
    )
    session.add_all([article, plat])
    await session.commit()
    return {
        "outlet": str(outlet.id), "magasin": magasin.id, "biere": biere.id,
        "article": str(article.id), "plat": str(plat.id),
    }


@pytest.fixture
async def ardoise(client, session, hotel_a, auth_a):
    hotel, _ = hotel_a
    room_type = RoomType(hotel_id=hotel.id, code="STD", label="Standard", default_rate=25_000)
    session.add(room_type)
    await session.flush()
    room = Room(hotel_id=hotel.id, number="101", room_type_id=room_type.id)
    session.add(room)
    await session.commit()
    guest = (
        await client.post(
            "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth_a
        )
    ).json()
    res_id, line_id, folio_id = str(uuid7()), str(uuid7()), str(uuid7())
    await client.post(
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
        headers=auth_a,
    )
    resp = await client.post(
        f"/api/v1/reservations/{res_id}/rooms/{line_id}/check-in",
        json={"room_id": str(room.id), "folio_id": folio_id},
        headers=auth_a,
    )
    assert resp.status_code == 200, resp.text
    return folio_id


async def _stock(session, produit: uuid.UUID, magasin: uuid.UUID) -> int:
    session.expire_all()
    level = await session.scalar(
        select(StockLevel).where(
            StockLevel.product_id == produit, StockLevel.stock_location_id == magasin
        )
    )
    return level.quantity if level is not None else 0


async def test_portee_sur_la_chambre_la_biere_sort_du_bar(client, session, auth_a, bar, ardoise):
    ligne = {
        "id": str(uuid7()), "category": "FNB", "label": "Biere", "quantity": 2,
        "unit_price": 1_500, "menu_item_id": bar["article"], "outlet_id": bar["outlet"],
    }
    r = await client.post(f"/api/v1/folios/{ardoise}/items", json=ligne, headers=auth_a)
    assert r.status_code == 201, r.text
    assert await _stock(session, bar["biere"], bar["magasin"]) == 8

    # Renvoyee par la file : elle ne sort pas deux fois.
    r = await client.post(f"/api/v1/folios/{ardoise}/items", json=ligne, headers=auth_a)
    assert r.status_code == 200
    assert await _stock(session, bar["biere"], bar["magasin"]) == 8


async def test_un_plat_du_jour_ne_touche_a_aucun_stock(client, session, auth_a, bar, ardoise):
    r = await client.post(
        f"/api/v1/folios/{ardoise}/items",
        json={"id": str(uuid7()), "category": "FNB", "label": "Plat du jour",
              "unit_price": 4_000, "menu_item_id": bar["plat"], "outlet_id": bar["outlet"]},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text
    assert await _stock(session, bar["biere"], bar["magasin"]) == 10


async def test_le_client_de_passage_fait_aussi_sortir_le_stock(client, session, auth_a, bar):
    # Encaisser exige une caisse ouverte (409 sinon).
    r = await client.post("/api/v1/cash-sessions", json={"opening_float": 0}, headers=auth_a)
    assert r.status_code in (200, 201), r.text
    vente = {
        "id": str(uuid7()),
        "outlet_id": bar["outlet"],
        "items": [{"id": str(uuid7()), "category": "FNB", "label": "Biere", "quantity": 3,
                   "unit_price": 1_500, "menu_item_id": bar["article"]}],
        "payment": {"id": str(uuid7()), "method": "CASH", "amount": 4_500},
    }
    r = await client.post("/api/v1/folios/walk-in", json=vente, headers=auth_a)
    assert r.status_code == 201, r.text
    assert await _stock(session, bar["biere"], bar["magasin"]) == 7


async def test_on_vend_meme_sous_zero(client, session, auth_a, bar, ardoise):
    r = await client.post(
        f"/api/v1/folios/{ardoise}/items",
        json={"id": str(uuid7()), "category": "FNB", "label": "Biere", "quantity": 12,
              "unit_price": 1_500, "menu_item_id": bar["article"], "outlet_id": bar["outlet"]},
        headers=auth_a,
    )
    assert r.status_code == 201, r.text
    assert await _stock(session, bar["biere"], bar["magasin"]) == -2
