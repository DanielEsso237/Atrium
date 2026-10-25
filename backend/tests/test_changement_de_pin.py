"""Le PIN passe a 6 chiffres pour tout le monde (25 octobre).

L'agent dont le code en a 4 en choisit un nouveau a sa connexion, et prouve
son ancien code : la route est sans session, comme le code oublie, parce que
la tablette hors ligne enfile le geste pour plus tard.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.core.security import hash_secret
from app.models import AuditLog, User

CHANGE = "/api/v1/auth/change-pin"
LOGIN = "/api/v1/auth/login"


@pytest.fixture
async def agent(session, hotel_a):
    """Un agent au PIN de 4 chiffres, d'avant la regle."""
    hotel, _ = hotel_a
    user = User(
        id=uuid.uuid4(), hotel_id=hotel.id, employee_code="BAR_A", first_name="Ines",
        last_name="Mbarga", pin_hash=hash_secret("4321"), is_active=True,
        must_change_password=False,
    )
    session.add(user)
    await session.commit()
    return user


def _corps(**extra) -> dict:
    return {"employee_code": "bar_a", "current_secret": "4321", "new_pin": "246810", **extra}


async def _connexion(client, secret: str) -> int:
    r = await client.post(LOGIN, json={"employee_code": "BAR_A", "password": secret})
    return r.status_code


@pytest.mark.db
async def test_l_agent_passe_a_six_chiffres_sans_session(client, session, agent):
    r = await client.post(CHANGE, json=_corps())

    assert r.status_code == 200, r.text
    assert r.json() == {"user_id": str(agent.id)}
    assert await _connexion(client, "246810") == 200
    assert await _connexion(client, "4321") == 401
    trace = await session.scalar(select(AuditLog).where(AuditLog.action == "CHANGE_PIN"))
    assert trace.user_id == agent.id
    # Aucune valeur dans la trace.
    assert trace.after is None


@pytest.mark.db
async def test_un_renvoi_apres_reponse_perdue_passe(client, session, agent):
    assert (await client.post(CHANGE, json=_corps())).status_code == 200

    # L'ancien code ne marche plus, mais le nouveau est deja en place.
    assert (await client.post(CHANGE, json=_corps())).status_code == 200
    await session.refresh(agent)
    assert agent.failed_login_count == 0


@pytest.mark.db
async def test_un_code_actuel_faux_compte_comme_un_echec(client, session, agent):
    r = await client.post(CHANGE, json=_corps(current_secret="0000"))

    assert r.status_code == 403
    await session.refresh(agent)
    assert agent.failed_login_count == 1
    assert await _connexion(client, "4321") == 200


@pytest.mark.db
async def test_cinq_codes_faux_bloquent(client, agent):
    for _ in range(5):
        await client.post(CHANGE, json=_corps(current_secret="0000"))

    assert (await client.post(CHANGE, json=_corps())).status_code == 423


@pytest.mark.parametrize("pin", ["1234", "12345", "1234567", "abcdef"])
async def test_le_nouveau_pin_fait_six_chiffres(client, pin):
    assert (await client.post(CHANGE, json=_corps(new_pin=pin))).status_code == 422
