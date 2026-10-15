"""L'inventaire d'un magasin (ticket O4) : ouvrir, compter, reequilibrer.

Ce qui compte : la quantite theorique est celle du serveur, figee a
l'ouverture ; un manque devient une perte, un surplus un ajustement ; un
seul inventaire ouvert par magasin ; et chaque route se rejoue sans rien
refaire -- un refus bloquerait la file de la tablette.
"""

from __future__ import annotations

import uuid
from types import SimpleNamespace

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.models import Product, StockLevel, StockMovement
from app.models.enums import StockMovementType
from app.services.stock_locations import ensure_central
from tests.test_transferts_stock import _agent

pytestmark = pytest.mark.db

URL = "/api/v1/inventories"


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def economat(session, hotel_a):
    """L'economat : 10 bieres et 5 savons en stock."""
    hotel, _ = hotel_a
    magasin = await ensure_central(session, hotel.id)
    produits = []
    for ref, label, quantite in (("BIE", "Biere", 10), ("SAV", "Savon", 5)):
        p = Product(
            id=uuid.uuid4(), hotel_id=hotel.id, reference=ref, label=label,
            purchase_price=600, sale_price=1500,
        )
        session.add(p)
        await session.flush()
        session.add(
            StockLevel(product_id=p.id, stock_location_id=magasin.id, quantity=quantite)
        )
        produits.append(p)
    await session.commit()
    # Des valeurs simples, pas des objets de la session : les routes la
    # partagent et l'expirent a chaque commit.
    return SimpleNamespace(id=magasin.id), [SimpleNamespace(id=p.id) for p in produits]


def _ouverture(magasin, produits):
    return {
        "id": str(uuid7()),
        "stock_location_id": str(magasin.id),
        "label": "Inventaire Economat",
        "lines": [{"id": str(uuid7()), "product_id": str(p.id)} for p in produits],
    }


async def _niveau(session, magasin, produit) -> int:
    magasin_id, produit_id = magasin.id, produit.id
    session.expire_all()
    return await session.scalar(
        select(StockLevel.quantity).where(
            StockLevel.stock_location_id == magasin_id,
            StockLevel.product_id == produit_id,
        )
    )


async def test_ouvrir_fige_le_theorique_et_se_rejoue(client, auth_a, economat):
    magasin, produits = economat
    corps = _ouverture(magasin, produits)

    r = await client.post(URL, json=corps, headers=auth_a)
    renvoi = await client.post(URL, json=corps, headers=auth_a)

    assert r.status_code == 201, r.text
    assert renvoi.status_code == 200, renvoi.text
    theorique = {l["product_id"]: l["theoretical_qty"] for l in r.json()["lines"]}
    assert theorique == {str(produits[0].id): 10, str(produits[1].id): 5}
    assert r.json()["status"] == "COUNTING"


async def test_un_seul_inventaire_ouvert_par_magasin(client, auth_a, economat):
    magasin, produits = economat
    await client.post(URL, json=_ouverture(magasin, produits), headers=auth_a)

    second = await client.post(URL, json=_ouverture(magasin, produits), headers=auth_a)

    assert second.status_code == 409, second.text


async def test_reequilibrer_manque_perte_surplus_ajustement(
    client, auth_a, economat, session
):
    magasin, (biere, savon) = economat
    corps = _ouverture(magasin, [biere, savon])
    inv = corps["id"]
    await client.post(URL, json=corps, headers=auth_a)
    # Une vente apres l'ouverture : le theorique fige ne bouge pas.
    niveau = await session.scalar(
        select(StockLevel).where(StockLevel.product_id == biere.id)
    )
    niveau.quantity = 9
    await session.commit()

    compte = await client.put(
        f"{URL}/{inv}/lines/{biere.id}", json={"counted_qty": 7}, headers=auth_a
    )
    renvoi = await client.put(
        f"{URL}/{inv}/lines/{biere.id}", json={"counted_qty": 7}, headers=auth_a
    )
    await client.put(
        f"{URL}/{inv}/lines/{savon.id}", json={"counted_qty": 6}, headers=auth_a
    )
    assert compte.status_code == 200, compte.text
    assert renvoi.status_code == 200, renvoi.text

    perte = str(uuid7())
    r = await client.post(
        f"{URL}/{inv}/rebalance",
        json={"movement_ids": {str(biere.id): perte}},
        headers=auth_a,
    )
    rejeu = await client.post(
        f"{URL}/{inv}/rebalance",
        json={"movement_ids": {str(biere.id): perte}},
        headers=auth_a,
    )

    assert r.status_code == 200, r.text
    assert rejeu.status_code == 200, rejeu.text
    assert r.json()["status"] == "CLOSED"
    mouvements = {
        m.product_id: m
        for m in (
            await session.scalars(
                select(StockMovement).where(StockMovement.source_id == uuid.UUID(inv))
            )
        ).all()
    }
    # Biere : 10 a l'ouverture, 7 comptees -> perte de 3, avec l'id de la
    # tablette et le cout du jour.
    assert mouvements[biere.id].id == uuid.UUID(perte)
    assert mouvements[biere.id].type == StockMovementType.LOSS
    assert mouvements[biere.id].quantity == 3
    assert mouvements[biere.id].unit_cost == 600
    # Savon : 5, 6 comptes -> ajustement de +1, id du serveur.
    assert mouvements[savon.id].type == StockMovementType.ADJUSTMENT
    assert mouvements[savon.id].quantity == 1
    # Le rejeu n'a rien compte deux fois.
    assert len(mouvements) == 2
    assert await _niveau(session, magasin, biere) == 9 - 3
    assert await _niveau(session, magasin, savon) == 6


async def test_les_lignes_non_comptees_ne_bougent_pas(
    client, auth_a, economat, session
):
    magasin, (biere, savon) = economat
    corps = _ouverture(magasin, [biere, savon])
    await client.post(URL, json=corps, headers=auth_a)
    await client.put(
        f"{URL}/{corps['id']}/lines/{biere.id}", json={"counted_qty": 10}, headers=auth_a
    )

    r = await client.post(f"{URL}/{corps['id']}/rebalance", json={}, headers=auth_a)

    assert r.status_code == 200, r.text
    assert await _niveau(session, magasin, savon) == 5
    assert await _niveau(session, magasin, biere) == 10


async def test_abandonner_puis_rouvrir(client, auth_a, economat):
    magasin, produits = economat
    corps = _ouverture(magasin, produits)
    await client.post(URL, json=corps, headers=auth_a)

    r = await client.post(f"{URL}/{corps['id']}/cancel", headers=auth_a)
    renvoi = await client.post(f"{URL}/{corps['id']}/cancel", headers=auth_a)
    nouveau = await client.post(URL, json=_ouverture(magasin, produits), headers=auth_a)

    assert r.status_code == 200 and r.json()["deleted_at"] is not None
    assert renvoi.status_code == 200
    assert nouveau.status_code == 201, nouveau.text


async def test_la_descente_rend_les_ouverts_et_les_abandonnes(client, auth_a, economat):
    magasin, produits = economat
    corps = _ouverture(magasin, produits)
    await client.post(URL, json=corps, headers=auth_a)

    ouverts = (await client.get(URL, headers=auth_a)).json()
    await client.post(f"{URL}/{corps['id']}/cancel", headers=auth_a)
    sans_since = (await client.get(URL, headers=auth_a)).json()
    depuis = (
        await client.get(URL, params={"since": "2000-01-01T00:00:00Z"}, headers=auth_a)
    ).json()

    assert [i["id"] for i in ouverts] == [corps["id"]]
    assert sans_since == []
    assert [i["id"] for i in depuis] == [corps["id"]]
    assert depuis[0]["deleted_at"] is not None


async def test_l_econome_compte_mais_ne_reequilibre_pas(
    client, session, hotel_a, login, economat
):
    hotel, _ = hotel_a
    magasin, produits = economat
    await _agent(session, hotel, "ECO_A", ["stock.read", "stock.inventory"])
    auth = {"Authorization": f"Bearer {await login(client, 'ECO_A')}"}
    corps = _ouverture(magasin, produits)

    ouvert = await client.post(URL, json=corps, headers=auth)
    await client.put(
        f"{URL}/{corps['id']}/lines/{produits[0].id}", json={"counted_qty": 1}, headers=auth
    )
    refus = await client.post(f"{URL}/{corps['id']}/rebalance", json={}, headers=auth)

    assert ouvert.status_code == 201, ouvert.text
    assert refus.status_code == 403
