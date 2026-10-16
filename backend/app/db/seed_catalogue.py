"""Points de vente, services et catalogue de demonstration.

Idempotent : identifiants fixes, `ON CONFLICT DO NOTHING` partout. Rejouer ne
cree rien en double et ne remet ni un libelle, ni un stock a sa valeur
initiale. Les liens (magasin, poste, produit) se resolvent par *code*, pas
par identifiant : une ligne creee a la main avec le meme code est reutilisee.

Le point de vente « Restaurant » (RESTO) est cree par `seed.py` ; ce module
lui ajoute seulement sa carte et son magasin.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    MenuCategory,
    MenuItem,
    Outlet,
    PrepStation,
    Product,
    StockLevel,
    StockLocation,
    StockMovement,
)
from app.models.enums import OutletKind, StockMovementType

O, S = OutletKind.OUTLET, OutletKind.SERVICE


def fixe(base: int, rang: int) -> uuid.UUID:
    return uuid.UUID(f"01920000-0000-7000-8000-{base + rang:012x}")


# (code, libelle)
MAGASINS = [
    ("STK-RESTO", "Stock restaurant"),
    ("STK-BAR", "Stock bar"),
    ("STK-BOUTIQUE", "Stock boutique"),
    ("STK-NIGHT", "Stock night club"),
]

# (code, libelle, genre, report en chambre, ordre) -- le Restaurant existe deja.
POINTS = [
    ("BAR", "Bar / Lounge", O, True, 1),
    ("BOUTIQUE", "Boutique de l'hôtel", O, True, 2),
    ("NIGHTCLUB", "Discothèque / Night Club", O, False, 3),
    ("SPA", "Spa", S, True, 10),
    ("PISCINE", "Piscine", S, True, 11),
    ("FITNESS", "Salle de sport / Fitness", S, True, 12),
    ("CONFERENCE", "Salle de conférence", S, False, 13),
    ("BANQUET", "Salle de banquet / Réception", S, False, 14),
]

# point de vente -> magasin dont il tire son stock
MAGASIN_DU_POINT = {
    "RESTO": "STK-RESTO",
    "BAR": "STK-BAR",
    "BOUTIQUE": "STK-BOUTIQUE",
    "NIGHTCLUB": "STK-NIGHT",
}

POSTES = [("CUISINE", "Cuisine"), ("BAR", "Bar")]

# (reference, libelle, prix d'achat, prix de vente, {magasin: quantite initiale})
PRODUITS = [
    ("EAU15", "Eau minérale 1,5 L", 400, 1_000, {"STK-RESTO": 60, "STK-BAR": 80}),
    ("COCA", "Coca-Cola 33 cl", 450, 1_000, {"STK-RESTO": 48, "STK-BAR": 96}),
    ("FLAG", "Flag 65 cl", 900, 1_500, {"STK-BAR": 120, "STK-NIGHT": 90}),
    ("CASTEL", "Castel 65 cl", 900, 1_500, {"STK-BAR": 100}),
    ("WHISKY", "Whisky (bouteille 70 cl)", 15_000, 25_000, {"STK-NIGHT": 12}),
    ("CHAMPAGNE", "Champagne (bouteille 75 cl)", 28_000, 45_000, {"STK-NIGHT": 6}),
    ("TSHIRT", "T-shirt Atrium", 3_500, 8_000, {"STK-BOUTIQUE": 25}),
    ("CREME", "Crème solaire", 3_000, 5_500, {"STK-BOUTIQUE": 15}),
    ("BROSSE", "Brosse à dents", 500, 1_500, {"STK-BOUTIQUE": 40}),
    ("CARTE", "Carte postale", 100, 500, {"STK-BOUTIQUE": 200}),
]

# point -> [(categorie, [(code, libelle, prix, poste, produit)])]
CATALOGUE = {
    "RESTO": [
        (
            "Plats",
            [
                ("RESTO-POULET", "Poulet braisé", 6_500, "CUISINE", None),
                ("RESTO-ATTIEKE", "Attiéké poisson", 6_000, "CUISINE", None),
                ("RESTO-RIZ", "Riz sauce graine", 4_500, "CUISINE", None),
                ("RESTO-BROCHETTES", "Brochettes de bœuf", 3_500, "CUISINE", None),
            ],
        ),
        ("Desserts", [("RESTO-FRUITS", "Salade de fruits", 2_000, "CUISINE", None)]),
        (
            "Boissons",
            [
                ("RESTO-EAU", "Eau minérale 1,5 L", 1_000, "BAR", "EAU15"),
                ("RESTO-COCA", "Coca-Cola 33 cl", 1_000, "BAR", "COCA"),
            ],
        ),
    ],
    "BAR": [
        (
            "Bières",
            [
                ("BAR-FLAG", "Flag 65 cl", 1_500, "BAR", "FLAG"),
                ("BAR-CASTEL", "Castel 65 cl", 1_500, "BAR", "CASTEL"),
            ],
        ),
        (
            "Cocktails",
            [
                ("BAR-MOJITO", "Mojito", 4_000, "BAR", None),
                ("BAR-PINA", "Piña colada", 4_500, "BAR", None),
            ],
        ),
        (
            "Softs",
            [
                ("BAR-COCA", "Coca-Cola 33 cl", 1_000, "BAR", "COCA"),
                ("BAR-EAU", "Eau minérale 1,5 L", 1_000, "BAR", "EAU15"),
            ],
        ),
    ],
    "BOUTIQUE": [
        (
            "Souvenirs",
            [
                ("BTQ-TSHIRT", "T-shirt Atrium", 8_000, None, "TSHIRT"),
                ("BTQ-CARTE", "Carte postale", 500, None, "CARTE"),
            ],
        ),
        (
            "Essentiels",
            [
                ("BTQ-CREME", "Crème solaire", 5_500, None, "CREME"),
                ("BTQ-BROSSE", "Brosse à dents", 1_500, None, "BROSSE"),
            ],
        ),
    ],
    "NIGHTCLUB": [
        ("Entrées", [("NC-ENTREE", "Entrée boîte de nuit", 5_000, None, None)]),
        (
            "Bouteilles",
            [
                ("NC-WHISKY", "Bouteille de whisky", 25_000, "BAR", "WHISKY"),
                ("NC-CHAMPAGNE", "Bouteille de champagne", 45_000, "BAR", "CHAMPAGNE"),
            ],
        ),
        ("Bières", [("NC-FLAG", "Flag 65 cl", 2_000, "BAR", "FLAG")]),
    ],
    "SPA": [
        (
            "Massages",
            [
                ("SPA-RELAX", "Massage relaxant 60 min", 25_000, None, None),
                ("SPA-PIERRES", "Massage aux pierres chaudes", 30_000, None, None),
            ],
        ),
        (
            "Soins",
            [
                ("SPA-VISAGE", "Soin du visage", 20_000, None, None),
                ("SPA-GOMMAGE", "Gommage corporel", 18_000, None, None),
            ],
        ),
    ],
    "PISCINE": [
        (
            "Accès",
            [
                ("PIS-ACCES", "Accès piscine (journée)", 3_000, None, None),
                ("PIS-TRANSAT", "Transat (location)", 1_000, None, None),
                ("PIS-SERVIETTE", "Serviette de piscine (location)", 500, None, None),
            ],
        ),
    ],
    "FITNESS": [
        (
            "Accès",
            [
                ("FIT-SEANCE", "Accès salle de sport (séance)", 2_000, None, None),
                ("FIT-MOIS", "Abonnement mensuel", 30_000, None, None),
            ],
        ),
        ("Coaching", [("FIT-COACH", "Coach personnel 1 h", 10_000, None, None)]),
    ],
    "CONFERENCE": [
        (
            "Location",
            [
                ("CONF-DEMI", "Salle de conférence : demi-journée", 150_000, None, None),
                ("CONF-JOUR", "Salle de conférence : journée complète", 250_000, None, None),
            ],
        ),
        (
            "Options",
            [
                ("CONF-PROJO", "Vidéoprojecteur", 20_000, None, None),
                ("CONF-PAUSE", "Pause-café (par personne)", 3_500, None, None),
            ],
        ),
    ],
    "BANQUET": [
        (
            "Location",
            [("BQT-SALLE", "Location salle de banquet (soirée)", 400_000, None, None)],
        ),
        (
            "Prestations",
            [
                ("BQT-MENU", "Menu banquet (par personne)", 15_000, "CUISINE", None),
                ("BQT-DECO", "Décoration de salle", 75_000, None, None),
                ("BQT-SONO", "Service sonorisation", 50_000, None, None),
            ],
        ),
    ],
}


async def seed_catalogue(session: AsyncSession, hotel_id: uuid.UUID) -> None:
    async def inserer(model, rows: list[dict]) -> None:
        if rows:
            await session.execute(insert(model).values(rows).on_conflict_do_nothing())

    async def par_code(model, colonne: str = "code") -> dict[str, uuid.UUID]:
        col = getattr(model, colonne)
        lignes = await session.execute(select(col, model.id).where(model.hotel_id == hotel_id))
        return {code: ident for code, ident in lignes.all()}

    # --- Magasins, points de vente, services ---
    await inserer(
        StockLocation,
        [
            {"id": fixe(0x8000, i), "hotel_id": hotel_id, "code": c, "label": lib, "sort_order": i}
            for i, (c, lib) in enumerate(MAGASINS, start=1)
        ],
    )
    magasins = await par_code(StockLocation)

    await inserer(
        Outlet,
        [
            {
                "id": fixe(0x7000, i),
                "hotel_id": hotel_id,
                "code": c,
                "label": lib,
                "kind": genre,
                "allows_room_charge": chambre,
                "sort_order": ordre,
            }
            for i, (c, lib, genre, chambre, ordre) in enumerate(POINTS, start=2)
        ],
    )
    points = await par_code(Outlet)
    for code, magasin in MAGASIN_DU_POINT.items():
        if code in points and magasin in magasins:
            # Seulement s'il n'en a pas : un magasin choisi a l'administration
            # n'est pas remis en cause par un nouveau passage du seed.
            await session.execute(
                update(Outlet)
                .where(Outlet.id == points[code], Outlet.stock_location_id.is_(None))
                .values(stock_location_id=magasins[magasin])
            )

    # --- Postes de preparation et produits ---
    await inserer(
        PrepStation,
        [
            {"id": fixe(0x7100, i), "hotel_id": hotel_id, "code": c, "label": lib, "sort_order": i}
            for i, (c, lib) in enumerate(POSTES, start=1)
        ],
    )
    postes = await par_code(PrepStation)

    await inserer(
        Product,
        [
            {
                "id": fixe(0x9000, i),
                "hotel_id": hotel_id,
                "reference": ref,
                "label": lib,
                "purchase_price": achat,
                "sale_price": vente,
                "is_sellable": True,
            }
            for i, (ref, lib, achat, vente, _) in enumerate(PRODUITS, start=1)
        ],
    )
    produits = await par_code(Product, "reference")

    # --- Stock initial : un niveau et son mouvement d'entree, ensemble ---
    maintenant = dt.datetime.now(dt.timezone.utc)
    paires, n = [], 0
    for ref, _, achat, _, parts in PRODUITS:
        for magasin, quantite in parts.items():
            n += 1
            niveau = {
                "id": fixe(0xA000, n),
                "product_id": produits[ref],
                "stock_location_id": magasins[magasin],
                "quantity": quantite,
                "last_movement_at": maintenant,
            }
            mouvement = {
                "id": fixe(0xB000, n),
                "hotel_id": hotel_id,
                "product_id": produits[ref],
                "stock_location_id": magasins[magasin],
                "type": StockMovementType.IN,
                "quantity": quantite,
                "unit_cost": achat,
                "reason": "Stock initial (données de test)",
                "moved_at": maintenant,
            }
            paires.append((niveau, mouvement))
    if paires:
        res = await session.execute(
            insert(StockLevel)
            .values([p[0] for p in paires])
            .on_conflict_do_nothing()
            .returning(StockLevel.id)
        )
        crees = set(res.scalars())
        # Pas de mouvement sans niveau : le journal et le compteur restent
        # d'accord, et un second passage ne double pas l'entree.
        await inserer(StockMovement, [m for niv, m in paires if niv["id"] in crees])

    # --- Cartes et prestations ---
    categories, articles, nc, na = [], [], 0, 0
    for code_point, groupes in CATALOGUE.items():
        if code_point not in points:
            continue
        for ordre, (libelle, lignes) in enumerate(groupes, start=1):
            nc += 1
            cat_id = fixe(0x7200, nc)
            categories.append(
                {
                    "id": cat_id,
                    "hotel_id": hotel_id,
                    "outlet_id": points[code_point],
                    "label": libelle,
                    "sort_order": ordre,
                }
            )
            for rang, (code, lib, prix, poste, ref) in enumerate(lignes, start=1):
                na += 1
                articles.append(
                    {
                        "id": fixe(0x7300, na),
                        "hotel_id": hotel_id,
                        "code": code,
                        "label": lib,
                        "menu_category_id": cat_id,
                        "price": prix,
                        "prep_station_id": postes[poste] if poste else None,
                        "product_id": produits[ref] if ref else None,
                        "sort_order": rang,
                    }
                )
    await inserer(MenuCategory, categories)
    await inserer(MenuItem, articles)