"""Remonter les ecritures d'un agent absent, sur le code d'un responsable.

Chaque agent ne remonte que ses ecritures : celles d'un agent qui ne repasse
plus restaient sur la tablette. `POST /auth/delegate` rend un jeton court a
son nom, qui ne sert qu'a ecrire, et chaque ecriture se trace au nom du
responsable.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.core.security import hash_secret
from app.models import AuditLog, Guest, Permission, Role, RolePermission, User, UserRole

pytestmark = pytest.mark.db


async def _agent(session, hotel, code, permissions, actif=True):
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
        is_active=actif,
        must_change_password=False,
    )
    session.add(agent)
    await session.flush()
    session.add(UserRole(user_id=agent.id, role_id=role.id))
    await session.commit()
    return agent


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _demande(auteur, code="CHEF_EA", secret="Test1234!") -> dict:
    return {
        "author_id": str(auteur.id),
        "employee_code": code,
        "secret": secret,
        "reason": "Parti sans se reconnecter",
    }


def _client(nom: str) -> dict:
    return {"id": str(uuid.uuid4()), "first_name": "Awa", "last_name": nom}


@pytest.fixture
async def monde(session, client, hotel_a, login):
    hotel, _ = hotel_a
    absent = await _agent(session, hotel, "RECEP_EA", ["guests.write"])
    await _agent(session, hotel, "MENAGE_EA", ["housekeeping.read"])
    chef = await _agent(session, hotel, "CHEF_EA", ["sync.monitor"])
    menage = await login(client, "MENAGE_EA")
    return absent, chef, menage


async def test_le_responsable_remonte_l_ecriture_de_l_absent(client, session, monde):
    absent, chef, menage = monde

    r = await client.post("/api/v1/auth/delegate", json=_demande(absent), headers=_h(menage))
    assert r.status_code == 200, r.text
    assert r.json()["approver"]["user_id"] == str(chef.id)
    jeton = r.json()["access_token"]

    corps = _client("Kone")
    r = await client.post("/api/v1/guests", json=corps, headers=_h(jeton))
    assert r.status_code == 201, r.text
    fiche = await session.get(Guest, uuid.UUID(corps["id"]))
    assert fiche is not None

    traces = (
        await session.scalars(
            select(AuditLog)
            .where(AuditLog.action.in_(["SYNC_DELEGATE", "SYNC_DELEGATED_WRITE"]))
            .order_by(AuditLog.occurred_at)
        )
    ).all()
    assert [t.action for t in traces] == ["SYNC_DELEGATE", "SYNC_DELEGATED_WRITE"]
    for t in traces:
        assert t.user_id == chef.id
        assert t.after["on_behalf_of"] == str(absent.id)
    assert traces[0].after["reason"] == "Parti sans se reconnecter"
    assert traces[1].after["path"] == "/api/v1/guests"


async def test_l_ecriture_se_juge_avec_les_droits_de_l_absent(
    client, session, hotel_a, login
):
    """Un administrateur qui delegue ne prete pas ses droits."""
    hotel, _ = hotel_a
    absent = await _agent(session, hotel, "BAR_EA", ["order.read"])
    await _agent(session, hotel, "CHEF_EA", ["sync.monitor", "guests.write"])
    jeton_bar = await login(client, "BAR_EA")

    r = await client.post("/api/v1/auth/delegate", json=_demande(absent), headers=_h(jeton_bar))
    jeton = r.json()["access_token"]
    r = await client.post("/api/v1/guests", json=_client("Sow"), headers=_h(jeton))
    assert r.status_code == 403


async def test_il_faut_un_responsable_et_son_code(client, session, hotel_a, monde):
    absent, _, menage = monde
    hotel, _ = hotel_a
    await _agent(session, hotel, "RECEP2_EA", ["guests.write"])

    r = await client.post(
        "/api/v1/auth/delegate", json=_demande(absent, secret="Faux0000!"), headers=_h(menage)
    )
    assert r.status_code == 403
    assert "incorrect" in r.json()["detail"]

    r = await client.post(
        "/api/v1/auth/delegate", json=_demande(absent, code="RECEP2_EA"), headers=_h(menage)
    )
    assert r.status_code == 403
    assert "sync.monitor" in r.json()["detail"]


async def test_le_jeton_ne_sert_qu_a_ecrire(client, monde):
    absent, _, menage = monde
    r = await client.post("/api/v1/auth/delegate", json=_demande(absent), headers=_h(menage))
    jeton = r.json()["access_token"]

    assert (await client.get("/api/v1/guests", headers=_h(jeton))).status_code == 403
    r = await client.post("/api/v1/auth/delegate", json=_demande(absent), headers=_h(jeton))
    assert r.status_code == 403


async def test_un_agent_parti_se_remonte_encore(client, session, hotel_a, monde, login):
    """Desactive, l'agent ne se connecte plus ; ses ecritures remontent."""
    _, _, menage = monde
    hotel, _ = hotel_a
    parti = await _agent(session, hotel, "PARTI_EA", ["guests.write"], actif=False)

    r = await client.post("/api/v1/auth/delegate", json=_demande(parti), headers=_h(menage))
    assert r.status_code == 200, r.text
    r = await client.post(
        "/api/v1/guests", json=_client("Ba"), headers=_h(r.json()["access_token"])
    )
    assert r.status_code == 201, r.text


async def test_pas_pour_l_agent_d_un_autre_hotel(client, hotel_b, monde):
    _, _, menage = monde
    _, admin_b = hotel_b
    r = await client.post("/api/v1/auth/delegate", json=_demande(admin_b), headers=_h(menage))
    assert r.status_code == 404
