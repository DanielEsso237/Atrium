"""Tests de cloisonnement multi-hotel (fix/hotel-scoping).

Chaque test suit le meme schema : une ligne est creee dans hotel_b, un
utilisateur de hotel_a interroge l'endpoint, et on verifie que cette ligne
n'apparait pas dans sa reponse.
"""

from __future__ import annotations

import uuid

import pytest

from app.models import (
    Room,
    RoomType,
    Outlet,
    PrepStation,
    RestaurantTable,
    MenuCategory,
    MenuItem,
    Supplier,
    ProductCategory,
    Product,
    StockLocation,
    Printer,
    DocumentType,
    PrintRoute,
    DocumentTemplate,
)
from app.models.enums import PrinterKind, PrinterProtocol, TemplateFormat


# --- Hebergement -----------------------------------------------------------


@pytest.mark.db
async def test_rooms_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    room_type = RoomType(
        id=uuid.uuid4(),
        hotel_id=hotel_b_obj.id,
        code="STD",
        label="Standard",
    )
    session.add(room_type)
    await session.flush()

    room = Room(
        id=uuid.uuid4(),
        hotel_id=hotel_b_obj.id,
        number="999",
        room_type_id=room_type.id,
        is_active=True,
    )
    session.add(room)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get(
        "/api/v1/rooms", headers={"Authorization": f"Bearer {token}"}
    )
    assert resp.status_code == 200, resp.text
    numbers = [r["number"] for r in resp.json()]
    assert "999" not in numbers


@pytest.mark.db
async def test_room_types_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    room_type = RoomType(
        id=uuid.uuid4(),
        hotel_id=hotel_b_obj.id,
        code="SUITE_B",
        label="Suite hotel B",
    )
    session.add(room_type)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get(
        "/api/v1/room-types", headers={"Authorization": f"Bearer {token}"}
    )
    assert resp.status_code == 200, resp.text
    codes = [rt["code"] for rt in resp.json()]
    assert "SUITE_B" not in codes


# --- Restauration ------------------------------------------------------------


@pytest.mark.db
async def test_outlets_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    outlet = Outlet(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, code="BAR_B", label="Bar hotel B")
    session.add(outlet)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get("/api/v1/outlets", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    codes = [o["code"] for o in resp.json()]
    assert "BAR_B" not in codes


@pytest.mark.db
async def test_prep_stations_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    station = PrepStation(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, code="CUISINE_B", label="Cuisine B")
    session.add(station)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get("/api/v1/prep-stations", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    codes = [s["code"] for s in resp.json()]
    assert "CUISINE_B" not in codes


@pytest.mark.db
async def test_tables_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    outlet = Outlet(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, code="REST_B", label="Restaurant B")
    session.add(outlet)
    await session.flush()

    table = RestaurantTable(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, outlet_id=outlet.id, number="T99")
    session.add(table)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get("/api/v1/tables", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    numbers = [t["number"] for t in resp.json()]
    assert "T99" not in numbers


@pytest.mark.db
async def test_menu_categories_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    category = MenuCategory(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, label="Desserts B")
    session.add(category)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get("/api/v1/menu-categories", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    labels = [c["label"] for c in resp.json()]
    assert "Desserts B" not in labels


@pytest.mark.db
async def test_menu_items_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    category = MenuCategory(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, label="Plats B")
    session.add(category)
    await session.flush()

    item = MenuItem(
        id=uuid.uuid4(),
        hotel_id=hotel_b_obj.id,
        code="PLAT_B",
        label="Plat hotel B",
        menu_category_id=category.id,
    )
    session.add(item)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get("/api/v1/menu-items", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    codes = [i["code"] for i in resp.json()]
    assert "PLAT_B" not in codes


# --- Stock ---------------------------------------------------------------------


@pytest.mark.db
async def test_suppliers_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    supplier = Supplier(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, code="FOURN_B", name="Fournisseur B")
    session.add(supplier)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get("/api/v1/suppliers", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    codes = [s["code"] for s in resp.json()]
    assert "FOURN_B" not in codes


@pytest.mark.db
async def test_product_categories_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    category = ProductCategory(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, label="Boissons B")
    session.add(category)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get("/api/v1/product-categories", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    labels = [c["label"] for c in resp.json()]
    assert "Boissons B" not in labels


@pytest.mark.db
async def test_products_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    product = Product(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, reference="REF_B", label="Produit B")
    session.add(product)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get("/api/v1/products", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    refs = [p["reference"] for p in resp.json()]
    assert "REF_B" not in refs


@pytest.mark.db
async def test_stock_locations_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    location = StockLocation(id=uuid.uuid4(), hotel_id=hotel_b_obj.id, code="ECON_B", label="Economat B")
    session.add(location)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get("/api/v1/stock-locations", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    codes = [l["code"] for l in resp.json()]
    assert "ECON_B" not in codes


# --- Impression ------------------------------------------------------------------


@pytest.mark.db
async def test_printers_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    printer = Printer(
        id=uuid.uuid4(),
        hotel_id=hotel_b_obj.id,
        logical_name="IMP_CUISINE_B",
        label="Imprimante cuisine B",
        kind=PrinterKind.THERMAL,
        protocol=PrinterProtocol.ESCPOS_NET,
    )
    session.add(printer)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get(
        "/api/v1/printers", headers={"Authorization": f"Bearer {token}"}
    )
    assert resp.status_code == 200, resp.text
    names = [p["logical_name"] for p in resp.json()]
    assert "IMP_CUISINE_B" not in names


@pytest.mark.db
async def test_document_types_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    doc_type = DocumentType(
        id=uuid.uuid4(),
        hotel_id=hotel_b_obj.id,
        code="FACTURE_B",
        label="Facture hotel B",
    )
    session.add(doc_type)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get(
        "/api/v1/document-types", headers={"Authorization": f"Bearer {token}"}
    )
    assert resp.status_code == 200, resp.text
    codes = [dt["code"] for dt in resp.json()]
    assert "FACTURE_B" not in codes


@pytest.mark.db
async def test_print_routes_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    doc_type = DocumentType(
        id=uuid.uuid4(), hotel_id=hotel_b_obj.id, code="FACTURE_B2", label="Facture B2"
    )
    session.add(doc_type)
    await session.flush()

    printer = Printer(
        id=uuid.uuid4(),
        hotel_id=hotel_b_obj.id,
        logical_name="IMP_CAISSE_B",
        label="Imprimante caisse B",
        kind=PrinterKind.THERMAL,
        protocol=PrinterProtocol.ESCPOS_NET,
    )
    session.add(printer)
    await session.flush()

    route = PrintRoute(
        id=uuid.uuid4(),
        hotel_id=hotel_b_obj.id,
        document_type_id=doc_type.id,
        printer_id=printer.id,
        label="Route B",
    )
    session.add(route)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get(
        "/api/v1/print-routes", headers={"Authorization": f"Bearer {token}"}
    )
    assert resp.status_code == 200, resp.text
    labels = [r["label"] for r in resp.json()]
    assert "Route B" not in labels


@pytest.mark.db
async def test_document_templates_hotel_a_ne_voit_pas_hotel_b(client, hotel_a, hotel_b, session, login):
    hotel_b_obj, _ = hotel_b

    doc_type = DocumentType(
        id=uuid.uuid4(), hotel_id=hotel_b_obj.id, code="FACTURE_B3", label="Facture B3"
    )
    session.add(doc_type)
    await session.flush()

    template = DocumentTemplate(
        id=uuid.uuid4(),
        hotel_id=hotel_b_obj.id,
        document_type_id=doc_type.id,
        version=1,
        format=TemplateFormat.HTML,
        content="<html></html>",
        label="Modele B",
    )
    session.add(template)
    await session.commit()

    _, user_a = hotel_a
    token = await login(client, user_a.employee_code)

    resp = await client.get(
        "/api/v1/document-templates", headers={"Authorization": f"Bearer {token}"}
    )
    assert resp.status_code == 200, resp.text
    labels = [t["label"] for t in resp.json()]
    assert "Modele B" not in labels