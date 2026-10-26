"""Une file d'envoi bloquee se voit d'un autre poste (migration 0034).

La tablette annonce son blocage hors de sa file, puis le dit leve. Tout
agent connecte peut annoncer -- le rapport part avec qui tient la tablette --,
seul `sync.monitor` relit les rapports.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.api.v1.devices import sans_secrets
from app.core.security import hash_secret
from app.models import Device, Permission, Role, RolePermission, SyncBlock, User, UserRole

pytestmark = pytest.mark.db

TABLETTE = uuid.UUID("01920000-0000-7000-8000-00000000ab12")


def _rapport(rapport_id: uuid.UUID, **extra) -> dict:
    corps = {
        "id": str(rapport_id),
        "device": {"id": str(TABLETTE), "name": "Tablette AB12", "app_version": "1.0.0"},
        "entity_table": "payments",
        "entity_id": str(uuid.uuid4()),
        "operation": "INSERT",
        "payload": {"amount": 15000, "method": "CASH"},
        "http_status": 409,
        "reason": "Aucune caisse ouverte.",
        "written_at": "2026-10-26T07:55:00Z",
        "blocked_at": "2026-10-26T08:00:00Z",
        "pending_behind": 3,
    }
    corps.update(extra)
    return corps


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


async def test_un_agent_sans_droit_annonce_son_blocage(client, session, hotel_a, login):
    """Le menage annonce le blocage du receptionniste : aucun droit requis."""
    hotel, _ = hotel_a
    recep = await _agent(session, hotel, "RECEP_SB", ["folio.write"])
    await _agent(session, hotel, "MENAGE_SB", ["housekeeping.read"])
    menage = await login(client, "MENAGE_SB")

    rapport_id = uuid.uuid4()
    r = await client.post(
        "/api/v1/sync-blocks", json=_rapport(rapport_id, author_id=str(recep.id)), headers=_h(menage)
    )
    assert r.status_code == 201, r.text
    corps = r.json()
    assert corps["status"] == "OPEN"
    assert corps["author_id"] == str(recep.id)
    assert corps["device_id"] == str(TABLETTE)

    # La tablette est enregistree au passage, sous son nom par defaut.
    tablette = await session.get(Device, TABLETTE)
    assert tablette is not None and tablette.name == "Tablette AB12"

    # Mais il ne relit pas les rapports.
    assert (await client.get("/api/v1/sync-blocks", headers=_h(menage))).status_code == 403
    assert (await client.get("/api/v1/devices", headers=_h(menage))).status_code == 403


async def test_un_rapport_renvoye_ne_fait_pas_doublon(client, session, hotel_a, login):
    token = await login(client, "ADMIN_A")
    rapport_id = uuid.uuid4()
    premier = await client.post("/api/v1/sync-blocks", json=_rapport(rapport_id), headers=_h(token))
    assert premier.status_code == 201

    second = await client.post(
        "/api/v1/sync-blocks", json=_rapport(rapport_id, pending_behind=7), headers=_h(token)
    )
    assert second.status_code == 200, second.text
    assert second.json()["pending_behind"] == 7

    lignes = (await session.scalars(select(SyncBlock))).all()
    assert len(lignes) == 1


async def test_les_secrets_ne_remontent_pas(client, hotel_a, login):
    token = await login(client, "ADMIN_A")
    r = await client.post(
        "/api/v1/sync-blocks",
        json=_rapport(
            uuid.uuid4(),
            entity_table="users",
            payload={
                "employee_code": "RECEP01",
                "new_pin": "123456",
                "approver_secret": "ChangeMe123!",
                "password": "x",
                "nested": {"pin_hash": "$2b$...", "shipping": "garde"},
            },
        ),
        headers=_h(token),
    )
    assert r.status_code == 201, r.text
    assert r.json()["payload"] == {"employee_code": "RECEP01", "nested": {"shipping": "garde"}}


def test_sans_secrets_par_mot_et_non_par_sous_chaine():
    assert sans_secrets({"opinion": 1, "pin": 2, "access_token": 3, "items": [{"hash": 4}]}) == {
        "opinion": 1,
        "items": [{}],
    }


async def test_un_autre_hotel_ne_touche_pas_au_rapport(client, hotel_a, hotel_b, login):
    token_a = await login(client, "ADMIN_A")
    token_b = await login(client, "ADMIN_B")
    rapport_id = uuid.uuid4()
    assert (
        await client.post("/api/v1/sync-blocks", json=_rapport(rapport_id), headers=_h(token_a))
    ).status_code == 201

    # Ni le rapport, ni la tablette d'un autre hotel.
    r = await client.post("/api/v1/sync-blocks", json=_rapport(rapport_id), headers=_h(token_b))
    assert r.status_code == 404
    r = await client.post("/api/v1/sync-blocks", json=_rapport(uuid.uuid4()), headers=_h(token_b))
    assert r.status_code == 404
    r = await client.post(
        f"/api/v1/sync-blocks/{rapport_id}/resolve",
        json={"resolution": "SENT", "resolved_at": "2026-10-26T09:00:00Z"},
        headers=_h(token_b),
    )
    assert r.status_code == 404
    assert (await client.get("/api/v1/sync-blocks", headers=_h(token_b))).json() == []
    assert (await client.get("/api/v1/devices", headers=_h(token_b))).json() == []


async def test_un_auteur_d_un_autre_hotel_n_est_pas_nomme(client, hotel_a, hotel_b, login):
    _, admin_b = hotel_b
    token = await login(client, "ADMIN_A")
    r = await client.post(
        "/api/v1/sync-blocks", json=_rapport(uuid.uuid4(), author_id=str(admin_b.id)), headers=_h(token)
    )
    assert r.status_code == 201
    assert r.json()["author_id"] is None


async def test_lever_un_blocage(client, hotel_a, login):
    token = await login(client, "ADMIN_A")
    rapport_id = uuid.uuid4()
    await client.post("/api/v1/sync-blocks", json=_rapport(rapport_id), headers=_h(token))

    leve = await client.post(
        f"/api/v1/sync-blocks/{rapport_id}/resolve",
        json={"resolution": "SENT", "resolved_at": "2026-10-26T09:00:00Z"},
        headers=_h(token),
    )
    assert leve.status_code == 200, leve.text
    assert leve.json()["status"] == "RESOLVED"
    assert leve.json()["resolution"] == "SENT"

    # Renvoyee, la levee ne change rien ; un rapport arrive en retard non plus.
    encore = await client.post(
        f"/api/v1/sync-blocks/{rapport_id}/resolve",
        json={"resolution": "REMOVED", "resolved_at": "2026-10-26T10:00:00Z"},
        headers=_h(token),
    )
    assert encore.json()["resolution"] == "SENT"
    tard = await client.post(
        "/api/v1/sync-blocks", json=_rapport(rapport_id, pending_behind=9), headers=_h(token)
    )
    assert tard.json()["status"] == "RESOLVED"
    assert tard.json()["pending_behind"] == 3

    # Un blocage leve reste a l'ecran une semaine.
    liste = (await client.get("/api/v1/sync-blocks", headers=_h(token))).json()
    assert [b["id"] for b in liste] == [str(rapport_id)]


async def test_une_levee_ancienne_ne_s_affiche_plus(client, session, hotel_a, login):
    token = await login(client, "ADMIN_A")
    rapport_id = uuid.uuid4()
    await client.post("/api/v1/sync-blocks", json=_rapport(rapport_id), headers=_h(token))
    await client.post(
        f"/api/v1/sync-blocks/{rapport_id}/resolve",
        json={"resolution": "SENT", "resolved_at": "2020-01-01T00:00:00Z"},
        headers=_h(token),
    )
    assert (await client.get("/api/v1/sync-blocks", headers=_h(token))).json() == []


async def test_la_tablette_se_presente_sans_perdre_son_nom(client, session, hotel_a, login):
    token = await login(client, "ADMIN_A")
    corps = {"id": str(TABLETTE), "name": "Tablette AB12", "app_version": "1.0.0"}
    r = await client.put("/api/v1/devices/me", json=corps, headers=_h(token))
    assert r.status_code == 200, r.text
    assert r.json()["last_seen_at"] is not None

    # L'administrateur la renomme ; la presentation suivante garde ce nom.
    tablette = await session.get(Device, TABLETTE)
    tablette.name = "Reception 1"
    await session.commit()
    r = await client.put(
        "/api/v1/devices/me", json={**corps, "app_version": "1.1.0"}, headers=_h(token)
    )
    assert r.json()["name"] == "Reception 1"
    assert r.json()["app_version"] == "1.1.0"

    liste = (await client.get("/api/v1/devices", headers=_h(token))).json()
    assert [d["name"] for d in liste] == ["Reception 1"]
