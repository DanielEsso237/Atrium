"""Inventaires d'essai : de quoi montrer l'ecran Inventaire.

Trois magasins en cours d'inventaire, a trois moments du comptage :
- l'economat, compte aux deux tiers, avec des manques et quelques surplus :
  les vues « A compter » et « Ecarts » ont chacune quelque chose a montrer ;
- le bar, entierement compte, pret a reequilibrer ;
- la cuisine, ouverte ce matin, rien encore de compte.

La quantite theorique est figee comme le serveur la fige a l'ouverture : le
stock du magasin a cet instant. Rien ne bouge dans le stock -- seul un
reequilibrage le ferait, et il se fait depuis la tablette.

**Rejouable** : identifiants fixes, et un magasin qui a deja un inventaire
ouvert n'en recoit pas d'autre (la regle du serveur). Pour repartir de zero,
abandonner l'inventaire depuis la tablette, puis relancer.

    cd backend
    python -m app.db.seed
    python -m app.db.donnees_essai
    python -m app.db.ventes_essai
    python -m app.db.inventaires_essai
"""

from __future__ import annotations

import asyncio
import datetime as dt
import random
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings
from app.db.seed import DEMO_ADMIN, HOTEL
from app.models import Hotel, Inventory, InventoryLine, Product, StockLevel, StockLocation
from app.models.enums import InventoryStatus
from app.services.business_day import business_date_for

# Un espace a part de ceux de `donnees_essai.py` et `ventes_essai.py`.
_ESPACE = uuid.UUID("7c2d4e91-0b3a-4f68-a1d5-9e8f7a6b5c40")


def _id(nature: str, cle: str) -> uuid.UUID:
    return uuid.uuid5(_ESPACE, f"{HOTEL}:{nature}:{cle}")


# (code du magasin, part comptee, ouvert il y a tant d'heures)
PLAN = [
    ("ECONOMAT", 2 / 3, 3),
    ("BAR", 1.0, 2),
    ("CUISINE", 0.0, 1),
]


def _compte(rng: random.Random, theorique: int) -> int:
    """Ce que le terrain trouve : souvent juste, parfois un manque, rarement plus."""
    tirage = rng.random()
    if tirage < 0.65:
        return max(theorique, 0)
    if tirage < 0.9:
        manque = rng.randint(1, max(1, theorique // 8))
        return max(theorique - manque, 0)
    return max(theorique, 0) + rng.randint(1, 3)


async def charger(session: AsyncSession) -> list[str]:
    hotel = await session.get(Hotel, HOTEL)
    maintenant = dt.datetime.now(dt.timezone.utc)
    produits = set(
        (await session.scalars(
            select(Product.id).where(Product.hotel_id == HOTEL, Product.deleted_at.is_(None))
        )).all()
    )
    rapport = []
    for code, part, heures in PLAN:
        magasin = await session.scalar(
            select(StockLocation).where(
                StockLocation.hotel_id == HOTEL,
                StockLocation.code == code,
                StockLocation.deleted_at.is_(None),
            )
        )
        if magasin is None:
            rapport.append(f"{code} : magasin absent, saute")
            continue
        ouvert = await session.scalar(
            select(Inventory.id).where(
                Inventory.stock_location_id == magasin.id,
                Inventory.deleted_at.is_(None),
                Inventory.status != InventoryStatus.CLOSED,
            )
        )
        if ouvert is not None:
            rapport.append(f"{magasin.label} : deja un inventaire ouvert")
            continue
        niveaux = (
            await session.scalars(
                select(StockLevel).where(StockLevel.stock_location_id == magasin.id)
            )
        ).all()
        # L'ordre fixe le tirage : deux lancements comptent la meme chose.
        niveaux = sorted(
            (n for n in niveaux if n.product_id in produits), key=lambda n: str(n.product_id)
        )
        if not niveaux:
            rapport.append(f"{magasin.label} : aucun article en stock, saute")
            continue

        ouvert_le = maintenant - dt.timedelta(hours=heures)
        # Une cle par ouverture : relance apres un abandon, l'inventaire est neuf.
        cle = f"{code}:{ouvert_le:%Y%m%d%H%M}"
        inv = Inventory(
            id=_id("inventaire", cle),
            hotel_id=HOTEL,
            stock_location_id=magasin.id,
            label=f"Inventaire {magasin.label}",
            status=InventoryStatus.COUNTING,
            inventory_date=business_date_for(ouvert_le, hotel.timezone, hotel.day_rollover_hour),
            started_at=ouvert_le,
            created_by=DEMO_ADMIN,
            updated_by=DEMO_ADMIN,
        )
        session.add(inv)
        await session.flush()

        rng = random.Random(cle)
        a_compter = round(len(niveaux) * part)
        comptes = set(rng.sample(range(len(niveaux)), a_compter))
        ecarts = 0
        for i, n in enumerate(niveaux):
            trouve = _compte(rng, n.quantity) if i in comptes else None
            ecart = 0 if trouve is None else trouve - n.quantity
            ecarts += ecart != 0
            session.add(
                InventoryLine(
                    id=_id("ligne", f"{cle}:{n.product_id}"),
                    inventory_id=inv.id,
                    product_id=n.product_id,
                    theoretical_qty=n.quantity,
                    counted_qty=trouve,
                    variance=ecart,
                    created_by=DEMO_ADMIN,
                    updated_by=DEMO_ADMIN if trouve is not None else None,
                )
            )
        rapport.append(
            f"{magasin.label} : {len(niveaux)} articles, {a_compter} comptes, {ecarts} ecarts"
        )
    await session.commit()
    return rapport


async def main() -> None:
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        rapport = await charger(session)
    await engine.dispose()
    print("\n".join(rapport))


if __name__ == "__main__":
    asyncio.run(main())
