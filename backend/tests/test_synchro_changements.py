"""`GET /sync/changes` : ce qu'une tablette doit relire, et rien d'autre.

Le cas qui justifie tout le mecanisme est le dernier : deux transactions
concurrentes, la plus lente validee apres une lecture. Avec un curseur
numerique (`change_seq`), son changement etait saute pour toujours.
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import pathlib
import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.models import Guest, Permission, Role, RolePermission
from app.services.synchro import changements_depuis

pytestmark = pytest.mark.db

_VERSIONS = pathlib.Path(__file__).resolve().parents[1] / "alembic" / "versions"


def _migration(nom: str):
    spec = importlib.util.spec_from_file_location(nom, _VERSIONS / f"{nom}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
async def journal(session):
    """Pose les declencheurs du journal, que `create_all` ignore.

    Rejoue le SQL des migrations 0002 et 0031 tel quel : les tests lisent le
    journal que la production ecrit, pas une imitation.
    """
    m0002 = _migration("0002_sync_sequence_triggers")
    m0031 = _migration("0031_journal_par_transaction")
    conn = await session.connection()
    await conn.execute(text(m0002.TRACK_FUNCTION))
    for table in m0002.SYNCED_TABLES:
        await conn.execute(text(f"DROP TRIGGER IF EXISTS trg_{table}_sync ON {table}"))
        await conn.execute(
            text(
                f"CREATE TRIGGER trg_{table}_sync BEFORE INSERT OR UPDATE ON {table} "
                "FOR EACH ROW EXECUTE FUNCTION atrium_track_change()"
            )
        )
    for instruction in m0031.instructions():
        await conn.execute(text(instruction))
    await session.commit()


def _client(hotel_id: uuid.UUID, nom: str) -> Guest:
    return Guest(
        id=uuid.uuid4(), hotel_id=hotel_id, code=f"CLI-{nom}", first_name=nom, last_name="Test"
    )


async def _changes(client, token: str, since: str | None = None) -> dict:
    params = {} if since is None else {"since": since}
    r = await client.get(
        "/api/v1/sync/changes", params=params, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_sans_curseur_tout_se_relit(client, hotel_a, login, journal):
    token = await login(client, "ADMIN_A")
    r = await _changes(client, token)
    assert r["full_resync"] is True
    assert r["cursor"]


async def test_rien_n_a_change(client, hotel_a, login, journal):
    token = await login(client, "ADMIN_A")
    curseur = (await _changes(client, token))["cursor"]
    r = await _changes(client, token, curseur)
    assert r == {"cursor": r["cursor"], "full_resync": False, "tables": [], "removed": {}}


async def test_un_client_cree_signale_les_clients(client, session, hotel_a, login, journal):
    hotel, _ = hotel_a
    token = await login(client, "ADMIN_A")
    curseur = (await _changes(client, token))["cursor"]

    session.add(_client(hotel.id, "Mbarga"))
    await session.commit()

    r = await _changes(client, token, curseur)
    assert r["tables"] == ["guests"]
    assert r["full_resync"] is False
    # Le curseur avance : le meme changement ne revient pas.
    assert (await _changes(client, token, r["cursor"]))["tables"] == []


async def test_une_ligne_retiree_est_nommee(client, session, hotel_a, login, journal):
    hotel, _ = hotel_a
    token = await login(client, "ADMIN_A")
    fiche = _client(hotel.id, "Ngo")
    session.add(fiche)
    await session.commit()
    curseur = (await _changes(client, token))["cursor"]

    fiche.deleted_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()

    r = await _changes(client, token, curseur)
    assert r["removed"] == {"guests": [str(fiche.id)]}


async def test_un_autre_hotel_ne_fait_rien_relire(
    client, session, hotel_a, hotel_b, login, journal
):
    hotel_autre, _ = hotel_b
    token = await login(client, "ADMIN_A")
    curseur = (await _changes(client, token))["cursor"]

    session.add(_client(hotel_autre.id, "Ailleurs"))
    await session.commit()

    assert (await _changes(client, token, curseur))["tables"] == []


async def test_un_droit_ajoute_a_un_role_signale_les_roles(
    client, session, hotel_a, login, journal
):
    """`role_permissions` n'a pas d'id : elle est notee au nom du role."""
    token = await login(client, "ADMIN_A")
    role = Role(id=uuid.uuid4(), code="ESSAI_SYNC", label="Essai", is_system=False)
    droit = Permission(id=uuid.uuid4(), code="essai.sync", label="Essai", module="test")
    session.add_all([role, droit])
    await session.commit()
    curseur = (await _changes(client, token))["cursor"]

    session.add(RolePermission(role_id=role.id, permission_id=droit.id))
    await session.commit()

    assert "roles" in (await _changes(client, token, curseur))["tables"]


@pytest.mark.parametrize(
    "curseur",
    [
        "abc",
        "2:1:",  # xmin apres xmax
        "5:9:3",  # transaction active hors des bornes
        "5:9:8,6",  # transactions actives dans le desordre
        "9223372036854775808:9223372036854775808:",  # au-dela de 64 bits
        "99999999999:99999999999:",  # une base reinstallee depuis
    ],
)
async def test_un_curseur_inutilisable_fait_tout_relire(
    client, hotel_a, login, journal, curseur
):
    """Illisible, refuse par PostgreSQL, ou venu d'une base reinstallee depuis."""
    token = await login(client, "ADMIN_A")
    r = await _changes(client, token, curseur)
    assert r["full_resync"] is True


async def test_une_transaction_lente_n_est_jamais_sautee(
    session, database_url, hotel_a, journal
):
    """A ecrit, B ecrit et valide, une tablette lit, puis A valide.

    A a pris son numero avant B : un curseur numerique, avance jusqu'a B, ne
    l'aurait plus jamais rendu. L'instantane, lui, sait que A n'etait pas
    validee a la lecture.
    """
    hotel, _ = hotel_a
    engine = create_async_engine(database_url)
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with sessions() as a, sessions() as b, sessions() as lecteur:
            a.add(_client(hotel.id, "Lent"))
            await a.flush()  # ecrit, numero pris, pas valide

            b.add(_client(hotel.id, "Rapide"))
            await b.commit()

            vu = await changements_depuis(lecteur, None, hotel.id)
            await lecteur.commit()

            await a.commit()

            suite = await changements_depuis(lecteur, vu.curseur, hotel.id)
            assert suite.complet is False
            assert suite.tables == {"guests"}
    finally:
        await engine.dispose()
