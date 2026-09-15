"""Jeu de donnees de demonstration du serveur.

Miroir exact de `frontend/lib/data/local/seed.dart` : memes identifiants,
memes codes, memes tarifs. Les deux cotes doivent decrire le meme
etablissement, sinon la premiere synchronisation creerait des doublons de
parametrage.

Les identifiants sont **fixes** et non generes. Le jeu est donc idempotent :
le rejouer met a jour les lignes existantes au lieu d'en creer de nouvelles.

    python -m app.db.seed
"""

from __future__ import annotations

import asyncio
import uuid

from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings
from app.models import Floor, Hotel, Room, RoomType

# --- Identifiants deterministes ---------------------------------------------
# Le prefixe 01920000 correspond a un horodatage fige : ces lignes ne viennent
# pas d'une saisie, elles font partie du parametrage livre.

HOTEL = uuid.UUID("01920000-0000-7000-8000-000000000001")

FLOORS = [
    (uuid.UUID("01920000-0000-7000-8000-000000000101"), "E1", "Rez-de-chaussee", 1),
    (uuid.UUID("01920000-0000-7000-8000-000000000102"), "E2", "Premier etage", 2),
    (uuid.UUID("01920000-0000-7000-8000-000000000103"), "E3", "Deuxieme etage", 3),
    (uuid.UUID("01920000-0000-7000-8000-000000000104"), "E4", "Troisieme etage", 4),
    (uuid.UUID("01920000-0000-7000-8000-000000000105"), "E5", "Quatrieme etage", 5),
]
F1, F2, F3, F4, F5 = (f[0] for f in FLOORS)

STANDARD = uuid.UUID("01920000-0000-7000-8000-000000000201")
CLASSIC = uuid.UUID("01920000-0000-7000-8000-000000000202")
VIP = uuid.UUID("01920000-0000-7000-8000-000000000203")
SUITE = uuid.UUID("01920000-0000-7000-8000-000000000204")

# Le tarif est porte par le **type**, jamais par la chambre : deux chambres de
# meme categorie se vendent au meme prix, et une revalorisation tient en une
# seule ecriture.
#
#            id        code   libelle      cap.  max  tarif (FCFA)
ROOM_TYPES = [
    (STANDARD, "STD", "Standard", 2, 2, 25_000),
    (CLASSIC, "CLS", "Classic", 2, 3, 35_000),
    (VIP, "VIP", "VIP", 2, 3, 60_000),
    (SUITE, "SUI", "Suite", 2, 4, 90_000),
]

# Dix-huit chambres sur cinq etages. Les numeros sont arbitraires : ils
# illustrent le principe, à savoir que le numero identifie la chambre tandis
# que le type porte la categorie et le prix. Deux chambres d'etages differents
# appartiennent parfaitement a la meme categorie.
ROOMS = [
    ("101", STANDARD, F1),
    ("102", STANDARD, F1),
    ("103", CLASSIC, F1),
    ("123", STANDARD, F1),
    ("201", CLASSIC, F2),
    ("202", CLASSIC, F2),
    ("203", VIP, F2),
    ("204", STANDARD, F2),
    ("301", CLASSIC, F3),
    ("302", STANDARD, F3),
    ("309", VIP, F3),
    ("401", STANDARD, F4),
    ("402", CLASSIC, F4),
    ("403", VIP, F4),
    ("501", SUITE, F5),
    ("502", SUITE, F5),
    ("510", VIP, F5),
    ("567", STANDARD, F5),
]


def room_id(number: str) -> uuid.UUID:
    """Identifiant derive du numero, stable d'une execution a l'autre.

    Le segment `03` distingue les chambres des etages (`01`) et des types
    (`02`).
    """
    return uuid.UUID(f"01920000-0000-7000-8000-00000003{number:0>4}")


async def seed(session: AsyncSession) -> None:
    """Insere ou met a jour le parametrage de demonstration."""

    async def upsert(model, rows: list[dict]) -> None:
        if not rows:
            return
        stmt = insert(model).values(rows)
        updatable = {
            c.name: stmt.excluded[c.name]
            for c in model.__table__.columns
            if c.name not in ("id", "created_at")
        }
        await session.execute(
            stmt.on_conflict_do_update(index_elements=["id"], set_=updatable)
        )

    await upsert(
        Hotel,
        [
            {
                "id": HOTEL,
                "code": "ATR",
                "name": "Hotel Atrium",
                "city": "Abidjan",
                "country": "Cote d'Ivoire",
                "currency": "XOF",
            }
        ],
    )

    await upsert(
        Floor,
        [
            {
                "id": fid,
                "hotel_id": HOTEL,
                "code": code,
                "label": label,
                "sort_order": order,
            }
            for fid, code, label, order in FLOORS
        ],
    )

    await upsert(
        RoomType,
        [
            {
                "id": tid,
                "hotel_id": HOTEL,
                "code": code,
                "label": label,
                "base_capacity": base,
                "max_capacity": maxi,
                "default_rate": rate,
                "sort_order": i,
            }
            for i, (tid, code, label, base, maxi, rate) in enumerate(ROOM_TYPES)
        ],
    )

    await upsert(
        Room,
        [
            {
                "id": room_id(number),
                "hotel_id": HOTEL,
                "number": number,
                "room_type_id": type_id,
                "floor_id": floor_id,
            }
            for number, type_id, floor_id in ROOMS
        ],
    )

    await session.commit()


async def main() -> None:
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        await seed(session)
    await engine.dispose()
    print(f"{len(ROOM_TYPES)} categories, {len(ROOMS)} chambres.")


if __name__ == "__main__":
    asyncio.run(main())
