"""Numerotation : format (pur) et unicite sous concurrence (PostgreSQL)."""

from __future__ import annotations

import asyncio
import uuid

import pytest

from app.services.numbering import DEFAULT_PREFIXES, Scope, format_number


def test_format_reprend_les_formats_historiques():
    assert format_number("RES-", 42, 6) == "RES-000042"
    assert format_number("FA-", 1, 6) == "FA-000001"
    assert format_number(None, 7, 3) == "007"


def test_depasse_le_remplissage_sans_tronquer():
    assert format_number("ORD-", 1_234_567, 6) == "ORD-1234567"


def test_chaque_portee_a_un_prefixe_distinct():
    assert set(DEFAULT_PREFIXES) == set(Scope)
    assert len(set(DEFAULT_PREFIXES.values())) == len(Scope)


# --- Concurrence ---------------------------------------------------------------
#
# Base neuve construite depuis les modeles (`create_all`) : ce test n'a besoin
# que de `hotels` et `number_sequences`, pas des triggers ni des vues.


@pytest.fixture
async def engine(database_url):
    from sqlalchemy.ext.asyncio import create_async_engine

    from app.db.base import Base

    engine = create_async_engine(database_url, pool_size=25, max_overflow=0)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


@pytest.mark.db
async def test_requetes_simultanees_donnent_des_numeros_distincts_et_continus(engine):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    from app.models import Hotel
    from app.services.numbering import next_number

    factory = async_sessionmaker(engine, expire_on_commit=False)
    hotel_id = uuid.uuid4()
    async with factory() as session:
        session.add(Hotel(id=hotel_id, code="T", name="Test"))
        await session.commit()

    async def emettre() -> str:
        async with factory() as session:
            number = await next_number(session, hotel_id, Scope.RESERVATION)
            await asyncio.sleep(0.01)  # elargit la fenetre de course
            await session.commit()
            return number

    # 20 premiers appels simultanes : couvre aussi la creation de la ligne.
    numbers = await asyncio.gather(*(emettre() for _ in range(20)))
    assert sorted(numbers) == [f"RES-{i:06d}" for i in range(1, 21)]


@pytest.mark.db
async def test_rollback_ne_laisse_pas_de_trou(engine):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    from app.models import Hotel
    from app.services.numbering import next_number

    factory = async_sessionmaker(engine, expire_on_commit=False)
    hotel_id = uuid.uuid4()
    async with factory() as session:
        session.add(Hotel(id=hotel_id, code="T", name="Test"))
        await session.commit()

    async with factory() as session:
        assert await next_number(session, hotel_id, Scope.INVOICE) == "FA-000001"
        await session.rollback()
    async with factory() as session:
        assert await next_number(session, hotel_id, Scope.INVOICE) == "FA-000001"
        await session.commit()
