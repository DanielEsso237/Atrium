"""Code oublie : un responsable le reinitialise sur place (21 octobre).

L'agent choisit un nouveau PIN, un nouveau mot de passe, ou les deux ; un
responsable (`users.reset_secret`) tape son propre code. Cinq codes faux
bloquent un agent jusqu'a ce qu'un responsable le debloque ; un responsable,
lui, attend un quart d'heure -- personne au-dessus de lui ne le debloquerait.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from sqlalchemy import select

from app.core.security import hash_secret
from app.models import AuditLog, Permission, Role, RolePermission, User, UserRole

RESET = "/api/v1/auth/reset-secret"
LOGIN = "/api/v1/auth/login"


@pytest.fixture
async def agent(session, hotel_a):
    """Un agent de reception, PIN 4321, sans droit de reinitialiser."""
    hotel, _ = hotel_a
    role = Role(id=uuid.uuid4(), code="TEST_RECEP", label="Reception", is_system=True)
    session.add(role)
    await session.flush()
    perm = await session.scalar(select(Permission).where(Permission.code == "folio.write"))
    session.add(RolePermission(role_id=role.id, permission_id=perm.id))
    user = User(
        id=uuid.uuid4(), hotel_id=hotel.id, employee_code="RECEP_A", first_name="Awa",
        last_name="Traore", pin_hash=hash_secret("4321"), is_active=True,
        must_change_password=False,
    )
    session.add(user)
    await session.flush()
    session.add(UserRole(user_id=user.id, role_id=role.id))
    await session.commit()
    return user


def _corps(**extra) -> dict:
    return {
        "employee_code": "recep_a",
        "approver_code": "ADMIN_A",
        "approver_secret": "Test1234!",
        **extra,
    }


async def _connexion(client, code: str, secret: str) -> int:
    r = await client.post(LOGIN, json={"employee_code": code, "password": secret})
    return r.status_code


@pytest.mark.db
async def test_un_responsable_donne_un_nouveau_pin_sans_session(client, session, agent, hotel_a):
    _, admin = hotel_a
    r = await client.post(RESET, json=_corps(new_pin="567890"))

    assert r.status_code == 200, r.text
    assert r.json() == {"user_id": str(agent.id), "approved_by": str(admin.id)}
    assert await _connexion(client, "RECEP_A", "567890") == 200
    assert await _connexion(client, "RECEP_A", "4321") == 401
    trace = await session.scalar(select(AuditLog).where(AuditLog.action == "RESET_SECRET"))
    assert trace.user_id == admin.id
    # Ce qui a change, jamais la valeur.
    assert trace.after == {"approved_by": str(admin.id), "pin": True, "password": False}

    # Rejouable : la tablette renvoie apres une reponse perdue.
    assert (await client.post(RESET, json=_corps(new_pin="567890"))).status_code == 200


@pytest.mark.db
async def test_le_pin_et_le_mot_de_passe_ensemble(client, agent):
    r = await client.post(RESET, json=_corps(new_pin="567890", new_password="Nouveau123"))

    assert r.status_code == 200, r.text
    assert await _connexion(client, "RECEP_A", "567890") == 200
    assert await _connexion(client, "RECEP_A", "Nouveau123") == 200


@pytest.mark.db
async def test_il_faut_au_moins_un_nouveau_secret(client, agent):
    assert (await client.post(RESET, json=_corps())).status_code == 422
    assert (await client.post(RESET, json=_corps(new_pin="12"))).status_code == 422
    assert (await client.post(RESET, json=_corps(new_password="court"))).status_code == 422


@pytest.mark.db
async def test_un_code_de_responsable_faux_ne_change_rien(client, session, agent, hotel_a):
    _, admin = hotel_a
    r = await client.post(RESET, json=_corps(approver_secret="0000", new_pin="567890"))

    assert r.status_code == 403
    assert await _connexion(client, "RECEP_A", "4321") == 200
    # L'essai compte contre le responsable : la route ne sert pas a deviner.
    admin_id = admin.id
    session.expire_all()
    assert (await session.get(User, admin_id)).failed_login_count == 1


@pytest.mark.db
async def test_sans_le_droit_ou_pour_soi_meme_c_est_non(client, session, agent, hotel_a):
    hotel, _ = hotel_a
    collegue = User(
        id=uuid.uuid4(), hotel_id=hotel.id, employee_code="RECEP_B", first_name="Ali",
        last_name="Kone", pin_hash=hash_secret("1111"), is_active=True,
        must_change_password=False,
    )
    session.add(collegue)
    await session.commit()

    sans_droit = await client.post(
        RESET, json=_corps(approver_code="RECEP_B", approver_secret="1111", new_pin="567890")
    )
    assert sans_droit.status_code == 403
    soi_meme = await client.post(
        RESET, json=_corps(employee_code="ADMIN_A", new_password="Nouveau123")
    )
    assert soi_meme.status_code == 403
    assert "propre code" in soi_meme.json()["detail"]
    assert (await client.post(RESET, json=_corps(employee_code="PERSONNE", new_pin="567890"))).status_code == 404


@pytest.mark.db
async def test_cinq_codes_faux_bloquent_l_agent_jusqu_au_responsable(client, session, agent):
    for _ in range(5):
        assert await _connexion(client, "RECEP_A", "0000") == 401
    assert await _connexion(client, "RECEP_A", "4321") == 423

    # Attendre ne suffit plus : meme une heure plus tard, bloque.
    agent_id = agent.id
    session.expire_all()
    bloque = await session.get(User, agent_id)
    bloque.locked_until = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=1)
    await session.commit()
    assert await _connexion(client, "RECEP_A", "4321") == 423

    assert (await client.post(RESET, json=_corps(new_pin="567890"))).status_code == 200
    assert await _connexion(client, "RECEP_A", "567890") == 200


@pytest.mark.db
async def test_un_responsable_bloque_attend_un_quart_d_heure(client, session, hotel_a):
    _, admin = hotel_a
    for _ in range(5):
        assert await _connexion(client, "ADMIN_A", "faux") == 401
    assert await _connexion(client, "ADMIN_A", "Test1234!") == 423

    admin_id = admin.id
    session.expire_all()
    bloque = await session.get(User, admin_id)
    assert bloque.locked_until is not None
    bloque.locked_until = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=1)
    await session.commit()
    assert await _connexion(client, "ADMIN_A", "Test1234!") == 200


@pytest.mark.db
async def test_les_empreintes_descendent_aux_agents_connectes(client, agent, hotel_a, hotel_b, login):
    assert (await client.get("/api/v1/auth/credentials")).status_code == 401

    token = await login(client, "ADMIN_A")
    r = await client.get("/api/v1/auth/credentials", headers={"Authorization": f"Bearer {token}"})

    assert r.status_code == 200, r.text
    par_code = {c["employee_code"]: c for c in r.json()}
    # L'hotel de l'agent connecte, pas un autre.
    assert set(par_code) == {"ADMIN_A", "RECEP_A"}
    assert par_code["RECEP_A"]["pin_hash"].startswith("$2")
    assert par_code["RECEP_A"]["failed_login_count"] == 0
    assert par_code["RECEP_A"]["roles"][0]["permissions"] == ["folio.write"]
