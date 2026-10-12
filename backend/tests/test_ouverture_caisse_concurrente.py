"""Deux ouvertures du meme tiroir en meme temps : la seconde rend la premiere.

L'index unique tranche entre les deux ; la perdante doit recevoir la caisse
gagnante (200), pas une erreur. Le 12 octobre, elle recevait un 500 : apres
le rollback, relire l'agent declenchait un chargement implicite interdit en
asynchrone (MissingGreenlet), et la file d'envoi de la tablette se bloquait.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.api.v1 import cash_sessions
from app.core.ids import uuid7
from app.core.security import hash_secret
from app.models import Permission, Role, RolePermission, User, UserRole
from app.models.restaurant import Outlet

pytestmark = pytest.mark.db


@pytest.fixture
async def bar(session, hotel_a):
    hotel, _ = hotel_a
    outlet = Outlet(hotel_id=hotel.id, code="BAR", label="Bar")
    session.add(outlet)
    await session.commit()
    return str(outlet.id)


@pytest.fixture
async def auth_bar(client, session, hotel_a, login):
    hotel, _ = hotel_a
    role = Role(id=uuid.uuid4(), code="R_BARMAN", label="Barman")
    session.add(role)
    await session.flush()
    perm = await session.scalar(select(Permission).where(Permission.code == "cash.session"))
    if perm is None:
        perm = Permission(id=uuid.uuid4(), code="cash.session", label="cash", module="cash")
        session.add(perm)
        await session.flush()
    session.add(RolePermission(role_id=role.id, permission_id=perm.id))
    agent = User(
        id=uuid.uuid4(),
        hotel_id=hotel.id,
        employee_code="BARMAN",
        first_name="Paul",
        last_name="Bar",
        password_hash=hash_secret("Test1234!"),
        is_active=True,
        must_change_password=False,
    )
    session.add(agent)
    await session.flush()
    session.add(UserRole(user_id=agent.id, role_id=role.id))
    await session.commit()
    return {"Authorization": f"Bearer {await login(client, 'BARMAN')}"}


async def test_la_perdante_recoit_la_caisse_gagnante(client, bar, auth_bar, monkeypatch):
    premiere = await client.post(
        "/api/v1/cash-sessions",
        json={"id": str(uuid7()), "opening_float": 5_000, "outlet_id": bar},
        headers=auth_bar,
    )
    assert premiere.status_code == 201, premiere.text

    # La course : la seconde demande ne voit pas encore la premiere quand
    # elle verifie, et ne la rencontre qu'a l'index unique.
    vraie = cash_sessions.open_session_id
    appels = {"n": 0}

    async def aveugle_une_fois(*args, **kwargs):
        appels["n"] += 1
        return None if appels["n"] == 1 else await vraie(*args, **kwargs)

    monkeypatch.setattr(cash_sessions, "open_session_id", aveugle_une_fois)

    seconde = await client.post(
        "/api/v1/cash-sessions",
        json={"id": str(uuid7()), "opening_float": 9_000, "outlet_id": bar},
        headers=auth_bar,
    )

    assert seconde.status_code == 200, seconde.text
    assert seconde.json()["id"] == premiere.json()["id"]
    # Le premier comptage fait foi.
    assert seconde.json()["opening_float"] == 5_000
