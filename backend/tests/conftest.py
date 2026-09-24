"""Fixtures partagees.

Deux familles de tests cohabitent ici :

- les tests **purs**, qui n'ont besoin d'aucune base et tournent partout, tout
  le temps. C'est la ou doit vivre le maximum de regles metier.
- les tests marques `@pytest.mark.db`, qui ont besoin d'un vrai PostgreSQL.
  Ils sont ignores automatiquement quand `TEST_DATABASE_URL` est absent, pour
  qu'un `pytest` sur une machine sans base reste vert au lieu de produire
  quarante erreurs de connexion qu'on apprend vite a ignorer.

Lancer les tests avec base :

    set TEST_DATABASE_URL=postgresql+asyncpg://atrium:...@localhost:5432/atrium_test
    pytest

La base de test est **creee et detruite a chaque session** : ne jamais pointer
`TEST_DATABASE_URL` sur la base de developpement.
"""

from __future__ import annotations

import os

import pytest

# SECRET_KEY est obligatoire depuis app/core/config.py. On la pose avant tout
# import de `app.*`, sinon la simple importation d'un module de l'application
# leverait une erreur de validation pendant la collecte des tests.
os.environ.setdefault("SECRET_KEY", "cle-de-test-uniquement-pour-pytest")
os.environ.setdefault("ENV", "dev")

TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL")


def pytest_collection_modifyitems(config, items):
    """Ignore les tests marques `db` quand aucune base de test n'est fournie."""
    if TEST_DATABASE_URL:
        return
    saute = pytest.mark.skip(
        reason="TEST_DATABASE_URL absent : test necessitant PostgreSQL ignore."
    )
    for item in items:
        if "db" in item.keywords:
            item.add_marker(saute)


@pytest.fixture(scope="session")
def database_url() -> str:
    """URL de la base de test, ou saute le test si elle n'est pas configuree."""
    if not TEST_DATABASE_URL:
        pytest.skip("TEST_DATABASE_URL absent.")
    return TEST_DATABASE_URL


# ---------------------------------------------------------------------------
# Fixtures de base de donnees -- fix/hotel-scoping
# ---------------------------------------------------------------------------

import uuid

from httpx import AsyncClient, ASGITransport
from sqlalchemy import select
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from app.main import app
from app.db.session import get_session
from app.core.security import hash_secret
from app.models import (
    Base,
    Hotel,
    User,
    Role,
    Permission,
    RolePermission,
    UserRole,
)

# Toutes les permissions dont les tests de cloisonnement ont besoin --
# une seule liste, pour ne pas la repeter a chaque route testee.
_PERMISSIONS_NEEDED = [
    "rooms.read", "rooms.write",
    "room_types.read", "room_types.write",
    "restaurant.read", "restaurant.write",
    "stock.read", "stock.write",
    "printing.read", "printing.write",
    "users.read",
    "guests.read", "guests.write",
    "reservation.read", "reservation.create", "reservation.manage",
    "folio.read", "folio.write",
]


@pytest.fixture
async def session(database_url):
    """Une base Postgres de test, vide au debut de chaque test, detruite

    a la fin. `TEST_DATABASE_URL` doit deja exister et etre vide au
    depart -- ne jamais pointer cette variable sur la base de dev.
    """
    engine = create_async_engine(database_url)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as s:
        yield s

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


async def _make_hotel_with_admin(session, code: str, employee_code: str):
    """Cree un hotel + un utilisateur qui a TOUTES les permissions testees.

    Les permissions sont un referentiel global (contrainte unique sur
    `code`, sans hotel_id) : on les reutilise si elles existent deja au
    lieu d'essayer de les recreer a chaque hotel de test.
    """
    hotel = Hotel(
        id=uuid.uuid4(),
        code=code,
        name=f"Hotel {code}",
        timezone="Africa/Abidjan",
        currency="XOF",
    )
    session.add(hotel)
    await session.flush()

    role = Role(id=uuid.uuid4(), code=f"TESTALL_{code}", label="Test all", is_system=True)
    session.add(role)
    await session.flush()

    result = await session.execute(
        select(Permission).where(Permission.code.in_(_PERMISSIONS_NEEDED))
    )
    existing = {p.code: p for p in result.scalars().all()}

    for perm_code in _PERMISSIONS_NEEDED:
        perm = existing.get(perm_code)
        if perm is None:
            perm = Permission(id=uuid.uuid4(), code=perm_code, label=perm_code, module="test")
            session.add(perm)
            await session.flush()
            existing[perm_code] = perm
        session.add(RolePermission(role_id=role.id, permission_id=perm.id))

    user = User(
        id=uuid.uuid4(),
        hotel_id=hotel.id,
        employee_code=employee_code,
        first_name="Test",
        last_name=code,
        password_hash=hash_secret("Test1234!"),
        is_active=True,
        must_change_password=False,
    )
    session.add(user)
    await session.flush()
    session.add(UserRole(user_id=user.id, role_id=role.id))

    await session.commit()
    return hotel, user


@pytest.fixture
async def hotel_a(session):
    return await _make_hotel_with_admin(session, "HTA", "ADMIN_A")


@pytest.fixture
async def hotel_b(session):
    return await _make_hotel_with_admin(session, "HTB", "ADMIN_B")


@pytest.fixture
async def client(session):
    """Client HTTP qui appelle l'app FastAPI directement (pas de vrai

    serveur reseau), en la faisant utiliser NOTRE session de test au lieu
    de la vraie base de dev.
    """
    async def _override_get_session():
        yield session

    app.dependency_overrides[get_session] = _override_get_session
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()


@pytest.fixture
def login():
    """Fixture qui expose la fonction de connexion aux tests.

    Evite un `from conftest import ...` : pytest injecte les fixtures par
    nom, sans jamais avoir besoin d'importer ce module comme un module
    normal (ce qui echoue selon la structure du package `tests/`).
    """

    async def _login(client, employee_code: str) -> str:
        resp = await client.post(
            "/api/v1/auth/login",
            json={"employee_code": employee_code, "password": "Test1234!"},
        )
        assert resp.status_code == 200, resp.text
        return resp.json()["access_token"]

    return _login