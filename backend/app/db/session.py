"""Session asynchrone SQLAlchemy pour l'API.

Alembic garde sa propre configuration synchrone (voir alembic/env.py) : les
migrations et l'API ne partagent pas le meme moteur, seulement la meme URL
de base (app.core.config.settings.database_url).
"""

from __future__ import annotations

from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings

# pool_size/max_overflow dimensionnes pour le paragraphe 6.1 du cahier des
# charges (50 tablettes simultanees minimum) : 20 connexions permanentes +
# 30 de debordement couvrent la charge sans epuiser PostgreSQL (dont
# max_connections vaut 100 par defaut).
engine = create_async_engine(
    settings.database_url,
    pool_pre_ping=True,
    pool_size=20,
    max_overflow=30,
)

SessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


async def get_session() -> AsyncGenerator[AsyncSession, None]:
    """Dependance FastAPI : une session par requete, fermee automatiquement."""
    async with SessionLocal() as session:
        yield session
