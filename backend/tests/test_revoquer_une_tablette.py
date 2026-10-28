"""Renommer et revoquer une tablette a distance (migration 0036).

Une tablette perdue ou volee garde sa base. Revoquee, elle recoit un 410 a
son prochain contact et efface sa base et sa cle ; ses sessions tombent tout
de suite.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.core.security import hash_secret
from app.models import AuditLog, Permission, RefreshToken, Role, RolePermission, User, UserRole

pytestmark = pytest.mark.db

TABLETTE = "01920000-0000-7000-8000-00000000cd34"


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
        first_name="Agent",
        last_name=code,
        password_hash=hash_secret("Test1234!"),
        is_active=True,
        must_change_password=False,
    )
    session.add(agent)
    await session.flush()
    session.add(UserRole(user_id=agent.id, role_id=role.id))
    await session.commit()
    return agent


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


async def _connecter(client, code, secret="Test1234!", tablette=TABLETTE):
    return await client.post(
        "/api/v1/auth/login",
        json={"employee_code": code, "password": secret, "device_id": tablette},
    )


async def _presenter(client, jeton):
    return await client.put(
        "/api/v1/devices/me",
        json={"id": TABLETTE, "name": "Tablette CD34"},
        headers=_h(jeton),
    )


@pytest.fixture
async def monde(session, client, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(session, hotel, "RECEP_RT", ["folio.write"])
    await _agent(session, hotel, "CHEF_RT", ["sync.monitor"])
    recep = await login(client, "RECEP_RT")
    assert (await _presenter(client, recep)).status_code == 200
    chef = await login(client, "CHEF_RT")
    return recep, chef


async def test_une_tablette_pas_encore_presentee_se_connecte(client, hotel_a, session):
    hotel, _ = hotel_a
    await _agent(session, hotel, "NEUF_RT", ["folio.write"])
    r = await _connecter(client, "NEUF_RT", tablette=str(uuid.uuid4()))
    assert r.status_code == 200, r.text


async def test_renommer(client, monde):
    recep, chef = monde
    r = await client.patch(
        f"/api/v1/devices/{TABLETTE}", json={"name": " Reception 1 "}, headers=_h(chef)
    )
    assert r.status_code == 200, r.text
    assert r.json()["name"] == "Reception 1"

    # La tablette se represente avec son nom par defaut : il ne revient pas.
    r = await _presenter(client, recep)
    assert r.json()["name"] == "Reception 1"

    r = await client.patch(
        f"/api/v1/devices/{TABLETTE}", json={"name": "Bar"}, headers=_h(recep)
    )
    assert r.status_code == 403


async def test_revoquer_coupe_ses_sessions_et_la_refuse(client, session, monde):
    recep, chef = monde
    connexion = await _connecter(client, "RECEP_RT")
    assert connexion.status_code == 200
    rafraichir = connexion.json()["refresh_token"]

    r = await client.post(
        f"/api/v1/devices/{TABLETTE}/revoke", json={"reason": "Volee au bar"}, headers=_h(chef)
    )
    assert r.status_code == 200, r.text
    assert r.json()["revoked_at"] is not None
    assert r.json()["revocation_reason"] == "Volee au bar"

    # Ses sessions tombent : plus de rafraichissement.
    assert (
        await session.scalar(
            select(RefreshToken).where(RefreshToken.device_id == uuid.UUID(TABLETTE))
        )
    ) is None
    r = await client.post("/api/v1/auth/refresh", json={"refresh_token": rafraichir})
    assert r.status_code == 401

    # Son prochain contact : 410, le refus dedie.
    assert (await _presenter(client, recep)).status_code == 410
    r = await _connecter(client, "RECEP_RT")
    assert r.status_code == 410
    assert "revoquee" in r.json()["detail"]
    # Meme sans le bon code : celui qui l'a trouvee n'en a pas besoin.
    assert (await _connecter(client, "RECEP_RT", secret="Faux0000!")).status_code == 410
    # Un rapport de blocage aussi.
    r = await client.post(
        "/api/v1/sync-blocks",
        json={
            "id": str(uuid.uuid4()),
            "device": {"id": TABLETTE, "name": "Tablette CD34"},
            "entity_table": "payments",
            "entity_id": str(uuid.uuid4()),
            "operation": "INSERT",
            "blocked_at": "2026-10-28T08:00:00Z",
        },
        headers=_h(recep),
    )
    assert r.status_code == 410

    trace = await session.scalar(select(AuditLog).where(AuditLog.action == "DEVICE_REVOKE"))
    assert trace is not None
    assert trace.after["reason"] == "Volee au bar"


async def test_la_premiere_revocation_fait_foi(client, monde):
    _, chef = monde
    url = f"/api/v1/devices/{TABLETTE}/revoke"
    await client.post(url, json={"reason": "Perdue"}, headers=_h(chef))
    r = await client.post(url, json={"reason": "Volee"}, headers=_h(chef))
    assert r.status_code == 200
    assert r.json()["revocation_reason"] == "Perdue"


async def test_revoquer_exige_sync_monitor(client, monde, hotel_b, login):
    recep, _ = monde
    r = await client.post(
        f"/api/v1/devices/{TABLETTE}/revoke", json={"reason": "Perdue"}, headers=_h(recep)
    )
    assert r.status_code == 403

    admin_b = await login(client, "ADMIN_B")
    r = await client.post(
        f"/api/v1/devices/{TABLETTE}/revoke", json={"reason": "Perdue"}, headers=_h(admin_b)
    )
    assert r.status_code == 404
