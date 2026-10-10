"""Les mouvements de stock : sans doublon, et les transferts valides.

L'economat ravitaille le bar ; le bar peut se ravitailler a la boite de nuit.
Un transfert attend sa validation (controleur ou comptable, un seul suffit) :
le stock ne bouge qu'a ce moment-la. Et le serveur ne refuse jamais un stock
negatif -- un refus bloquerait la file d'envoi de la tablette.

Trois metiers, trois gestes : l'econome tient l'economat, les points de vente
demandent leur ravitaillement, le controleur ou le comptable valide. Et celui
qui demande ne valide jamais sa propre demande, quels que soient ses droits.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import (
    Outlet,
    Permission,
    Product,
    Role,
    RolePermission,
    StockLevel,
    User,
    UserRole,
)
from app.services.stock_locations import ensure_central, ensure_outlet_location

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


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


@pytest.fixture
async def auth_controleur(client, session, hotel_a, login):
    """Le second regard : il lit le stock et valide, rien d'autre."""
    hotel, _ = hotel_a
    await _agent(session, hotel, "CONTROLE_A", ["stock.read", "stock.transfer.approve"])
    return {"Authorization": f"Bearer {await login(client, 'CONTROLE_A')}"}


@pytest.fixture
async def auth_barman(client, session, hotel_a, login):
    """Un point de vente : il lit son stock et demande son ravitaillement."""
    hotel, _ = hotel_a
    await _agent(session, hotel, "BARMAN_A", ["stock.read", "stock.transfer.request"])
    return {"Authorization": f"Bearer {await login(client, 'BARMAN_A')}"}


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


async def test_un_transfert_attend_sa_validation(
    client, session, auth_a, auth_controleur, magasins
):
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
        f"/api/v1/stock-movements/{transfert['id']}/approve", json={}, headers=auth_controleur
    )
    assert ok.status_code == 200, ok.text
    assert ok.json()["status"] == "APPROVED"
    assert await _quantite(session, m["biere"], m["economat"]) == 24
    assert await _quantite(session, m["biere"], m["bar"]) == 24

    # Validation rejouee : rien ne bouge une seconde fois.
    encore = await client.post(
        f"/api/v1/stock-movements/{transfert['id']}/approve", json={}, headers=auth_controleur
    )
    assert encore.status_code == 200
    assert await _quantite(session, m["biere"], m["bar"]) == 24


async def test_un_point_de_vente_se_ravitaille_chez_un_autre(
    client, session, auth_a, auth_controleur, magasins
):
    m = magasins
    await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["boite"],
                     type="IN", quantity=10)
    r = await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["boite"],
                         type="TRANSFER", quantity=4, counterpart_location_id=m["bar"])
    await client.post(
        f"/api/v1/stock-movements/{r.json()['id']}/approve", json={}, headers=auth_controleur
    )

    assert await _quantite(session, m["biere"], m["boite"]) == 6
    assert await _quantite(session, m["biere"], m["bar"]) == 4


async def test_un_transfert_refuse_ne_bouge_rien(
    client, session, auth_a, auth_controleur, magasins
):
    m = magasins
    r = await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["economat"],
                         type="TRANSFER", quantity=5, counterpart_location_id=m["bar"])
    non = await client.post(
        f"/api/v1/stock-movements/{r.json()['id']}/reject",
        json={"note": "Le bar en a encore"}, headers=auth_controleur,
    )
    assert non.status_code == 200, non.text
    assert (non.json()["status"], non.json()["decision_note"]) == ("REJECTED", "Le bar en a encore")
    assert await _quantite(session, m["biere"], m["bar"]) == 0

    # Refuse puis valide : non. Le contraire non plus.
    tard = await client.post(
        f"/api/v1/stock-movements/{r.json()['id']}/approve", json={}, headers=auth_controleur
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


async def test_qui_demande_un_transfert_ne_le_valide_pas(
    client, session, auth_a, auth_controleur, magasins
):
    # ADMIN_A porte les deux droits : c'est l'identite qui l'arrete, pas la
    # permission.
    m = magasins
    r = await _mouvement(client, auth_a, product_id=m["biere"], stock_location_id=m["economat"],
                         type="TRANSFER", quantity=6, counterpart_location_id=m["bar"])
    adresse = f"/api/v1/stock-movements/{r.json()['id']}/approve"

    seul = await client.post(adresse, json={}, headers=auth_a)
    assert seul.status_code == 403, seul.text
    assert "lui-meme" in seul.json()["detail"]
    # Rien n'a bouge, et le transfert attend toujours.
    assert await _quantite(session, m["biere"], m["bar"]) == 0

    autre = await client.post(adresse, json={}, headers=auth_controleur)
    assert autre.status_code == 200, autre.text
    assert autre.json()["status"] == "APPROVED"
    assert autre.json()["decided_by"] != autre.json()["moved_by"]
    assert await _quantite(session, m["biere"], m["bar"]) == 6


async def test_un_point_de_vente_demande_mais_ne_tient_pas_l_economat(
    client, session, auth_barman, auth_controleur, magasins
):
    m = magasins
    demande = await _mouvement(
        client, auth_barman, product_id=m["biere"], stock_location_id=m["economat"],
        type="TRANSFER", quantity=12, counterpart_location_id=m["bar"],
    )
    assert demande.status_code == 201, demande.text
    assert demande.json()["status"] == "PENDING"

    # Ni livraison, ni validation : ce sont les gestes de l'econome et du
    # controleur.
    entree = await _mouvement(client, auth_barman, product_id=m["biere"],
                              stock_location_id=m["bar"], type="IN", quantity=12)
    assert entree.status_code == 403
    valide = await client.post(
        f"/api/v1/stock-movements/{demande.json()['id']}/approve", json={}, headers=auth_barman
    )
    assert valide.status_code == 403
    assert await _quantite(session, m["biere"], m["bar"]) == 0

    ok = await client.post(
        f"/api/v1/stock-movements/{demande.json()['id']}/approve", json={},
        headers=auth_controleur,
    )
    assert ok.status_code == 200, ok.text
    assert await _quantite(session, m["biere"], m["bar"]) == 12


async def test_le_controleur_valide_mais_ne_demande_ni_ne_saisit(
    client, auth_controleur, magasins
):
    m = magasins
    demande = await _mouvement(
        client, auth_controleur, product_id=m["biere"], stock_location_id=m["economat"],
        type="TRANSFER", quantity=1, counterpart_location_id=m["bar"],
    )
    entree = await _mouvement(client, auth_controleur, product_id=m["biere"],
                              stock_location_id=m["economat"], type="IN", quantity=1)
    assert (demande.status_code, entree.status_code) == (403, 403)
