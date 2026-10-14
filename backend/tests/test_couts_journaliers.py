"""Ce que chaque journee a coute en stock, pour le benefice de la tablette.

La tablette ne recoit pas les mouvements de stock ; elle recoit ces totaux.
Ce qui compte : chaque cout tombe dans la bonne rubrique et la bonne
journee -- une vente a sa journee de vente, le reste a la journee hoteliere
de son mouvement, qui commence a 6 h et non a minuit.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest

from app.models import Folio, FolioItem, Product, StockMovement
from app.models.enums import (
    ChargeCategory,
    FolioStatus,
    FolioType,
    StockMovementStatus,
    StockMovementType,
)
from app.services.stock_locations import ensure_central

pytestmark = pytest.mark.db

URL = "/api/v1/accounting/daily-costs"
JOUR = dt.date(2026, 3, 10)


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def _mouvement(
    session, hotel, produit, magasin, genre, quantite, instant, **champs
):
    session.add(
        StockMovement(
            id=uuid.uuid4(),
            hotel_id=hotel.id,
            product_id=produit.id,
            stock_location_id=magasin.id,
            type=genre,
            quantity=quantite,
            moved_at=instant,
            status=StockMovementStatus.APPROVED,
            **champs,
        )
    )


async def test_chaque_cout_dans_sa_rubrique_et_sa_journee(
    client, session, hotel_a, auth_a
):
    hotel, _ = hotel_a
    # L'hotel de test est a l'heure d'Abidjan (UTC), bascule a 6 h.
    produit = Product(
        id=uuid.uuid4(),
        hotel_id=hotel.id,
        reference="BIERE",
        label="Biere",
        purchase_price=400,
        average_cost=500,
    )
    session.add(produit)
    magasin = await ensure_central(session, hotel.id)
    await session.flush()
    midi = dt.datetime.combine(JOUR, dt.time(12), dt.timezone.utc)

    # Une livraison payee 450 l'unite.
    await _mouvement(
        session, hotel, produit, magasin, StockMovementType.IN, 24, midi, unit_cost=450
    )
    # Une sortie sans vente a 3 h du matin : encore la journee de la veille.
    await _mouvement(
        session,
        hotel,
        produit,
        magasin,
        StockMovementType.OUT,
        2,
        dt.datetime.combine(JOUR, dt.time(3), dt.timezone.utc),
        unit_cost=500,
    )
    # Une casse, sans cout fige : au cout du produit aujourd'hui (500).
    await _mouvement(session, hotel, produit, magasin, StockMovementType.LOSS, 1, midi)
    # Une vente le 10, sortie le 11 au matin : elle compte le 10.
    folio = Folio(
        id=uuid.uuid4(),
        hotel_id=hotel.id,
        number="FOL-T1",
        type=FolioType.WALK_IN,
        status=FolioStatus.CLOSED,
    )
    session.add(folio)
    await session.flush()
    for annulee in (False, True):
        ligne = FolioItem(
            id=uuid.uuid4(),
            folio_id=folio.id,
            category=ChargeCategory.FNB,
            label="Biere",
            quantity=3,
            unit_price=1500,
            amount=4500,
            tax_amount=0,
            tax_rate=0,
            business_date=JOUR,
            is_void=annulee,
        )
        session.add(ligne)
        await session.flush()
        await _mouvement(
            session,
            hotel,
            produit,
            magasin,
            StockMovementType.OUT,
            3,
            dt.datetime.combine(
                JOUR + dt.timedelta(days=1), dt.time(8), dt.timezone.utc
            ),
            unit_cost=480,
            source_table="folio_items",
            source_id=ligne.id,
        )
    await session.commit()

    r = await client.get(
        URL,
        params={
            "since": (JOUR - dt.timedelta(days=1)).isoformat(),
            "until": JOUR.isoformat(),
        },
        headers=auth_a,
    )

    assert r.status_code == 200, r.text
    assert r.json() == [
        {
            "business_date": (JOUR - dt.timedelta(days=1)).isoformat(),
            "cost_of_sales": 0,
            "consumption": 2 * 500,
            "losses": 0,
            "purchases": 0,
        },
        {
            # La ligne annulee ne coute rien.
            "business_date": JOUR.isoformat(),
            "cost_of_sales": 3 * 480,
            "consumption": 0,
            "losses": 500,
            "purchases": 24 * 450,
        },
    ]


async def test_reserve_a_accounting_read(client, session, hotel_a, login):
    from tests.test_client_de_passage import _agent

    hotel, _ = hotel_a
    await _agent(session, hotel, "CJ_C", ["order.create"])
    headers = {"Authorization": f"Bearer {await login(client, 'CJ_C')}"}

    r = await client.get(URL, params={"since": JOUR.isoformat()}, headers=headers)

    assert r.status_code == 403
