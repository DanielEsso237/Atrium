"""Stocks d'essai : de quoi montrer chaque etat de l'ecran Stocks.

Apres `ventes_essai.py`, l'economat est bien garni et le bar tient tout juste
son seuil : l'ecran n'affiche presque que « En stock ». Ce jeu fait ce
qu'une mauvaise semaine ferait aussi :
- des ruptures : un lot de crevettes jete, le champagne parti pour un
  mariage, la Guinness du bar epuisee un soir de match ;
- du stock sous zero : le pain et les oeufs sortis pour un seminaire alors
  que la livraison n'a pas ete saisie, la Castel vendue au bar avant son
  ravitaillement ;
- du stock bas : riz, huile, savon et papier toilette sous leur seuil, et
  le Coca de l'economat passe au bar ;
- deux demandes de transfert de plus, faites par le comptoir : un
  administrateur peut les valider (celui qui demande ne valide pas).

Chaque quantite passe par un mouvement et `apply_movement`, comme a la
tablette : le journal des mouvements explique ce que l'ecran affiche.

**Rejouable** : un identifiant fixe par jour. Relance le meme jour, rien ne
bouge ; un autre jour, apres un nouveau `ventes_essai`, les etats reviennent.

    cd backend
    python -m app.db.seed
    python -m app.db.donnees_essai
    python -m app.db.ventes_essai
    python -m app.db.stock_essai
"""

from __future__ import annotations

import asyncio
import datetime as dt
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings
from app.db.seed import DEMO_ADMIN, HOTEL
from app.models import Hotel, Product, StockLevel, StockLocation, StockMovement, User
from app.models.enums import StockMovementStatus, StockMovementType
from app.services.business_day import business_date_for
from app.services.costing import unit_cost_of
from app.services.stock_levels import apply_movement

# Un espace a part de ceux des autres jeux d'essai.
_ESPACE = uuid.UUID("5b8f1c37-9d24-4e6a-b0c3-2f7e6d5a4b91")


def _id(nature: str, cle: str) -> uuid.UUID:
    return uuid.uuid5(_ESPACE, f"{HOTEL}:{nature}:{cle}")


_OUT, _LOSS, _TRANSFER = (
    StockMovementType.OUT,
    StockMovementType.LOSS,
    StockMovementType.TRANSFER,
)

# (magasin, reference, quantite visee, mouvement, motif, magasin d'arrivee).
# Zero : une rupture. Sous zero : une sortie plus grande que le stock connu.
# Au-dessus : sous le seuil du produit, il faut ravitailler.
ETATS = [
    ("ECONOMAT", "CREVETTES", 0, _LOSS, "Chaîne du froid rompue, lot jeté", None),
    ("ECONOMAT", "MOET", 0, _OUT, "Mariage en salle de banquet", None),
    ("ECONOMAT", "CHOCOLAT", 0, _OUT, "Sortie pâtisserie", None),
    ("ECONOMAT", "PAIN", -12, _OUT, "Petit-déjeuner du séminaire (livraison non saisie)", None),
    ("ECONOMAT", "OEUFS", -3, _OUT, "Sortie cuisine (livraison non saisie)", None),
    ("ECONOMAT", "RIZ", 18, _OUT, "Utilisé en cuisine", None),
    ("ECONOMAT", "HUILE_VEG", 6, _OUT, "Utilisé en cuisine", None),
    ("ECONOMAT", "SAVON", 8, _OUT, "Utilisé pour les chambres", None),
    ("ECONOMAT", "PAPIER_TOILETTE", 25, _OUT, "Utilisé pour les chambres", None),
    ("ECONOMAT", "COCA", 10, _TRANSFER, "Ravitaillement Bar / Lounge", "BAR"),
    ("BAR", "GUINNESS", 0, _OUT, "Soirée du match", None),
    ("BAR", "CASTEL", -6, _OUT, "Ventes du week-end (ravitaillement non saisi)", None),
    ("BAR", "DJINO", 5, _LOSS, "Casier tombé", None),
]

# Les demandes qui attendent le controleur : (magasin d'arrivee, reference,
# quantite, agent qui demande).
DEMANDES = [
    ("BAR", "TOP_PAMPLE", 24, "COMPTOIR01"),
    ("CAFE", "CAFE_GRAINS", 4, "COMPTOIR02"),
]


async def charger(session: AsyncSession) -> list[str]:
    hotel = await session.get(Hotel, HOTEL)
    maintenant = dt.datetime.now(dt.timezone.utc)
    jour = business_date_for(maintenant, hotel.timezone, hotel.day_rollover_hour)
    produits = {
        p.reference: p
        for p in (await session.scalars(
            select(Product).where(Product.hotel_id == HOTEL, Product.deleted_at.is_(None))
        )).all()
    }
    lieux = {
        lieu.code: lieu
        for lieu in (await session.scalars(
            select(StockLocation).where(
                StockLocation.hotel_id == HOTEL, StockLocation.deleted_at.is_(None)
            )
        )).all()
    }
    agents = {
        u.employee_code: u.id
        for u in (await session.scalars(select(User).where(User.hotel_id == HOTEL))).all()
    }
    if "ECONOMAT" not in lieux or not produits:
        raise SystemExit(
            "Pas d'economat ni de produits : lancez d'abord python -m app.db.donnees_essai."
        )

    rapport = []
    for rang, (code, ref, vise, nature, motif, vers) in enumerate(ETATS):
        lieu, produit = lieux.get(code), produits.get(ref)
        if lieu is None or produit is None or (vers is not None and vers not in lieux):
            rapport.append(f"{code} {ref} : absent, saute")
            continue
        id_ = _id("mouvement", f"{jour}:{code}:{ref}")
        if await session.get(StockMovement, id_) is not None:
            continue
        niveau = await session.scalar(
            select(StockLevel.quantity).where(
                StockLevel.stock_location_id == lieu.id, StockLevel.product_id == produit.id
            )
        )
        quantite = (niveau or 0) - vise
        if quantite <= 0:
            rapport.append(f"{lieu.label} {produit.label} : deja a {niveau}")
            continue
        # Etales sur la journee, du plus ancien au plus recent : le journal
        # les montre dans l'ordre ou ils sont arrives.
        quand = maintenant - dt.timedelta(minutes=15 * (len(ETATS) - rang))
        m = StockMovement(
            id=id_,
            hotel_id=HOTEL,
            product_id=produit.id,
            stock_location_id=lieu.id,
            counterpart_location_id=lieux[vers].id if vers else None,
            type=nature,
            quantity=quantite,
            unit_cost=0 if nature == _TRANSFER else unit_cost_of(produit),
            reason=motif,
            status=StockMovementStatus.APPROVED,
            decided_by=DEMO_ADMIN if nature == _TRANSFER else None,
            decided_at=quand if nature == _TRANSFER else None,
            moved_at=quand,
            moved_by=DEMO_ADMIN,
            created_at=quand,
        )
        session.add(m)
        await session.flush()
        await apply_movement(session, m)
        rapport.append(f"{lieu.label} {produit.label} : {niveau} -> {vise}")

    for vers, ref, quantite, agent in DEMANDES:
        lieu, produit = lieux.get(vers), produits.get(ref)
        if lieu is None or produit is None:
            continue
        id_ = _id("demande", f"{jour}:{vers}:{ref}")
        if await session.get(StockMovement, id_) is not None:
            continue
        quand = maintenant - dt.timedelta(minutes=5)
        session.add(
            StockMovement(
                id=id_,
                hotel_id=HOTEL,
                product_id=produit.id,
                stock_location_id=lieux["ECONOMAT"].id,
                counterpart_location_id=lieu.id,
                type=_TRANSFER,
                quantity=quantite,
                reason=f"Ravitaillement {lieu.label}",
                status=StockMovementStatus.PENDING,
                moved_at=quand,
                moved_by=agents.get(agent, DEMO_ADMIN),
                created_at=quand,
            )
        )
        rapport.append(f"Demande en attente : {quantite} {produit.unit} {produit.label} -> {lieu.label}")
    await session.commit()
    return rapport


async def main() -> None:
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        rapport = await charger(session)
    await engine.dispose()
    print("\n".join(rapport) or "Deja charge aujourd'hui : rien de plus.")


if __name__ == "__main__":
    asyncio.run(main())
