"""Activite de demonstration cote serveur.

Pendant exact de `frontend/lib/data/local/seed_activity.dart`, **avec les
memes identifiants**. C'est tout l'interet : quand la tablette rapatrie le
parc, elle ecrase ses propres lignes par celles du serveur, et les deux cotes
racontent alors la meme journee au lieu de se contredire.

Sans ce fichier, le serveur n'a que son parametrage -- dix-huit chambres
toutes libres et propres, aucun client, aucune reservation. Une tablette qui
se synchronise repassait donc son plan entierement au vert tout en gardant
ses huit reservations locales : « 0 chambre occupee » a cote de « 8
reservations en cours ».

Volontairement separe de `seed.py`, qui porte le parametrage livre. Celui-ci
invente une journee et se supprime d'un bloc le jour ou l'hotel saisit ses
vraies donnees.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import uuid

from sqlalchemy import text
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings
from app.db.seed import HOTEL, room_id
from app.services.business_day import current_business_date
from app.models import (
    Folio,
    FolioItem,
    Guest,
    Reservation,
    ReservationRoom,
    Room,
)
from app.models.enums import (
    ChargeCategory,
    FolioStatus,
    FolioType,
    HousekeepingStatus,
    OccupancyStatus,
    ReservationSource,
    ReservationStatus,
)


def _id(suffixe: str) -> uuid.UUID:
    """Identifiant deterministe, identique a celui de la tablette."""
    return uuid.UUID(f"01920000-0000-7000-8000-000000{suffixe}".ljust(36, "0")[:36])


# Etat force de douze chambres, pour que le plan montre ses cinq couleurs.
# Les numeros doivent exister dans seed.py.
ETATS = [
    ("101", OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, False),
    ("102", OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, False),
    ("103", OccupancyStatus.VACANT, HousekeepingStatus.DIRTY, False),
    ("123", OccupancyStatus.RESERVED, HousekeepingStatus.CLEAN, False),
    ("201", OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, False),
    ("202", OccupancyStatus.VACANT, HousekeepingStatus.DIRTY, False),
    ("203", OccupancyStatus.RESERVED, HousekeepingStatus.CLEAN, False),
    ("204", OccupancyStatus.VACANT, HousekeepingStatus.IN_PROGRESS, False),
    ("301", OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, False),
    ("302", OccupancyStatus.VACANT, HousekeepingStatus.DIRTY, False),
    ("309", OccupancyStatus.VACANT, HousekeepingStatus.CLEAN, True),
    ("401", OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, False),
]

# (cle, prenom, nom, chambre, arrivee en jours, nuits, tarif, statut)
SEJOURS = [
    ("01", "Amadou", "Kone", "101", -2, 4, 25000, ReservationStatus.CHECKED_IN),
    ("02", "Fatou", "Diallo", "102", -1, 3, 45000, ReservationStatus.CHECKED_IN),
    ("03", "Kwame", "Mensah", "201", 0, 2, 60000, ReservationStatus.CHECKED_IN),
    ("04", "Aline", "Bamba", "301", 0, 5, 25000, ReservationStatus.CHECKED_IN),
    ("05", "Ibrahim", "Toure", "401", -3, 3, 45000, ReservationStatus.CHECKED_IN),
    ("06", "Sarah", "Nguessan", "123", 0, 2, 25000, ReservationStatus.CONFIRMED),
    ("07", "Paul", "Yao", "203", 0, 1, 60000, ReservationStatus.CONFIRMED),
    ("08", "Marie", "Kouassi", "202", 1, 3, 45000, ReservationStatus.CONFIRMED),
]

# Consommations du jour, pour que le chiffre d'affaires ne soit pas nul.
CHARGES = [
    ("01", ChargeCategory.FNB, "Diner restaurant", 18500),
    ("01", ChargeCategory.MINIBAR, "Minibar - 2 boissons", 3000),
    ("02", ChargeCategory.FNB, "Petit dejeuner x2", 9000),
    ("03", ChargeCategory.FNB, "Room service", 22000),
    ("03", ChargeCategory.SPA, "Massage 60 min", 35000),
    ("04", ChargeCategory.FNB, "Bar - cocktails", 12500),
    ("05", ChargeCategory.LAUNDRY, "Blanchisserie", 7500),
]


async def seed_activity(session: AsyncSession) -> None:
    now = dt.datetime.now(dt.timezone.utc)

    # La journee hoteliere, pas la date du serveur. Semer a 3 h du matin
    # attribuerait sinon le chiffre d'affaires au mauvais jour -- exactement
    # le defaut corrige dans l'API par `app/services/business_day.py`.
    today = await current_business_date(session, HOTEL)

    async def upsert(model, rows: list[dict]) -> None:
        if not rows:
            return
        stmt = insert(model).values(rows)
        await session.execute(
            stmt.on_conflict_do_update(
                index_elements=["id"],
                set_={
                    c.name: stmt.excluded[c.name]
                    for c in model.__table__.columns
                    if c.name != "id"
                },
            )
        )

    # --- Clients ---
    await upsert(
        Guest,
        [
            {
                "id": _id(f"07{cle}"),
                "hotel_id": HOTEL,
                "code": f"CLI-{cle}",
                "first_name": prenom,
                "last_name": nom,
            }
            for cle, prenom, nom, *_ in SEJOURS
        ],
    )

    # --- Reservations et lignes de sejour ---
    # La categorie vient de la chambre : elle est deja en base, inutile de la
    # redecrire ici et de risquer une divergence.
    types = {}
    for _, _, _, numero, *_ in SEJOURS:
        r = await session.get(Room, room_id(numero))
        if r is not None:
            types[numero] = r.room_type_id

    reservations, lignes, folios, items = [], [], [], []

    for cle, _, _, numero, decalage, nuits, tarif, statut in SEJOURS:
        if numero not in types:
            continue  # chambre absente du parametrage : on saute
        arrivee = today + dt.timedelta(days=decalage)
        depart = arrivee + dt.timedelta(days=nuits)

        reservations.append(
            {
                "id": _id(f"08{cle}"),
                "hotel_id": HOTEL,
                "reference": f"RES-0000{cle}",
                "guest_id": _id(f"07{cle}"),
                "status": statut,
                "source": ReservationSource.DIRECT,
                "arrival_date": arrivee,
                "departure_date": depart,
                "estimated_total": tarif * nuits,
            }
        )
        lignes.append(
            {
                "id": _id(f"09{cle}"),
                "reservation_id": _id(f"08{cle}"),
                "room_type_id": types[numero],
                "room_id": room_id(numero),
                "arrival_date": arrivee,
                "departure_date": depart,
                "nightly_rate": tarif,
                "status": statut,
                "checked_in_at": now if statut == ReservationStatus.CHECKED_IN else None,
            }
        )

        # Une ardoise n'existe que pour un sejour en cours : rien ne se
        # consomme avant d'etre arrive.
        if statut == ReservationStatus.CHECKED_IN:
            folios.append(
                {
                    "id": _id(f"10{cle}"),
                    "hotel_id": HOTEL,
                    "number": f"FOL-0000{cle}",
                    "type": FolioType.GUEST,
                    "status": FolioStatus.OPEN,
                    "reservation_room_id": _id(f"09{cle}"),
                    "guest_id": _id(f"07{cle}"),
                }
            )

    await upsert(Reservation, reservations)
    await upsert(ReservationRoom, lignes)
    await upsert(Folio, folios)

    # --- Consommations, puis les nuitees du jour ---
    for rang, (cle, categorie, libelle, montant) in enumerate(CHARGES, start=1):
        items.append(
            {
                "id": _id(f"11{rang:02d}"),
                "folio_id": _id(f"10{cle}"),
                "category": categorie,
                "label": libelle,
                "unit_price": montant,
                "amount": montant,
                "business_date": today,
            }
        )

    rang = 0
    for cle, _, _, _, _, _, tarif, statut in SEJOURS:
        if statut != ReservationStatus.CHECKED_IN:
            continue
        rang += 1
        items.append(
            {
                "id": _id(f"12{rang:02d}"),
                "folio_id": _id(f"10{cle}"),
                "category": ChargeCategory.ROOM,
                "label": f"Nuitee du {today}",
                "unit_price": tarif,
                "amount": tarif,
                "business_date": today,
            }
        )

    await upsert(FolioItem, items)

    # --- Etats des chambres ---
    # En dernier : les trois axes sont ecrits separement, et le check-in
    # ci-dessus ne les touche pas. C'est la decision n°1 du projet.
    for numero, occupation, menage, hors_service in ETATS:
        chambre = await session.get(Room, room_id(numero))
        if chambre is None:
            continue
        chambre.occupancy_status = occupation
        chambre.housekeeping_status = menage
        chambre.is_out_of_order = hors_service

    # Les totaux du folio sont materialises : on les recalcule en SQL, comme
    # le fait `_recompute_totals` de l'API. En SQL et non en Python : c'est
    # PostgreSQL qui fait la somme, donc le resultat ne depend pas de ce que
    # ce script avait en memoire.
    await session.execute(
        text(
            """
            UPDATE folios f
               SET charges_total = COALESCE(s.total, 0),
                   balance       = COALESCE(s.total, 0) - f.payments_total
              FROM (SELECT folio_id, SUM(amount) AS total
                      FROM folio_items
                     WHERE deleted_at IS NULL
                     GROUP BY folio_id) s
             WHERE s.folio_id = f.id
            """
        )
    )

    await session.commit()


async def main() -> None:
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        await seed_activity(session)
    await engine.dispose()
    print(
        f"{len(SEJOURS)} sejours, {len(CHARGES)} consommations, "
        f"{len(ETATS)} chambres mises dans un etat."
    )


if __name__ == "__main__":
    asyncio.run(main())
