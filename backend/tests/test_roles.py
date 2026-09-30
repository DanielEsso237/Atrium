"""Les permissions d'un role, depuis l'administration.

La regle de la carte : on ne retire pas la derniere permission
d'administration. Un hotel sans aucun agent actif portant `users.write` ne
se repare pas depuis l'application -- il faudrait passer par la base.
"""

from __future__ import annotations

import pytest
from sqlalchemy import select

from app.models import Role

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


@pytest.fixture
async def role_admin(session, hotel_a):
    """Le seul role qui porte users.write dans l'hotel de test."""
    _, admin = hotel_a
    await session.refresh(admin, attribute_names=["roles"])
    return admin.roles[0].code


async def test_le_catalogue_des_permissions(client, auth_a):
    resp = await client.get("/api/v1/permissions", headers=auth_a)

    assert resp.status_code == 200, resp.text
    assert "users.write" in {p["code"] for p in resp.json()}


async def test_retirer_la_derniere_permission_d_administration_est_refuse(
    client, auth_a, role_admin
):
    resp = await client.put(
        f"/api/v1/roles/{role_admin}/permissions",
        json={"permissions": ["guests.read"]},
        headers=auth_a,
    )

    assert resp.status_code == 409, resp.text


async def test_les_permissions_d_un_role_se_remplacent(client, session, auth_a):
    session.add(Role(code="BARMAN", label="Barman"))
    await session.commit()

    resp = await client.put(
        "/api/v1/roles/BARMAN/permissions",
        json={"permissions": ["order.read", "order.create"]},
        headers=auth_a,
    )

    assert resp.status_code == 200, resp.text
    assert resp.json()["permissions"] == ["order.create", "order.read"]
    rejoue = await client.put(
        "/api/v1/roles/BARMAN/permissions",
        json={"permissions": ["order.read", "order.create"]},
        headers=auth_a,
    )
    assert rejoue.status_code == 200


async def test_une_permission_inconnue_est_refusee(client, session, auth_a):
    session.add(Role(code="BARMAN", label="Barman"))
    await session.commit()

    resp = await client.put(
        "/api/v1/roles/BARMAN/permissions",
        json={"permissions": ["n.existe.pas"]},
        headers=auth_a,
    )

    assert resp.status_code == 422


async def test_on_garde_l_administration_si_un_autre_role_la_porte(
    client, session, auth_a, role_admin, hotel_a
):
    # Un second role d'administration, porte par l'admin : retirer users.write
    # du premier ne laisse pas l'hotel sans administrateur.
    await client.put(
        f"/api/v1/roles/{role_admin}/permissions",
        json={"permissions": ["users.write", "users.read"]},
        headers=auth_a,
    )
    session.add(Role(code="ADMIN2", label="Admin bis"))
    await session.commit()
    await client.put(
        "/api/v1/roles/ADMIN2/permissions",
        json={"permissions": ["users.write", "users.read"]},
        headers=auth_a,
    )
    _, admin = hotel_a
    role2 = await session.scalar(select(Role).where(Role.code == "ADMIN2"))
    from app.models import UserRole

    session.add(UserRole(user_id=admin.id, role_id=role2.id))
    await session.commit()

    resp = await client.put(
        f"/api/v1/roles/{role_admin}/permissions",
        json={"permissions": ["users.read"]},
        headers=auth_a,
    )

    assert resp.status_code == 200, resp.text
