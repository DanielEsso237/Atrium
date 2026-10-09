"""Donnees d'essai d'Edge Hotel : points de vente, services, produits
camerounais, stocks et cartes.

Pour les essais sur tablette et les demonstrations. **Rejouable** : chaque
ligne a un identifiant fixe, derive de son code ; relancer le script met les
libelles et les prix a jour sans rien dupliquer, et un mouvement de stock deja
charge n'est jamais recompte.

    cd backend
    .venv\\Scripts\\activate
    python -m alembic upgrade head
    python -m app.db.donnees_essai

Ne touche ni aux reservations, ni aux clients, ni aux ardoises. Les points de
vente deja crees a la main (meme code) sont repris, pas doublonnes.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings
from app.db.seed import DEMO_ADMIN, HOTEL
from app.models import (
    MenuCategory,
    MenuItem,
    Outlet,
    Product,
    ProductCategory,
    StockLocation,
    StockMovement,
    Supplier,
)
from app.models.enums import OutletKind, StockMovementStatus, StockMovementType
from app.services.stock_levels import apply_movement
from app.services.stock_locations import ensure_central, ensure_outlet_location

# Espace des identifiants fixes : le meme code donne toujours le meme id.
_ESPACE = uuid.UUID("6f1c2b3a-9d8e-4f70-a1b2-c3d4e5f60708")


def _id(nature: str, code: str) -> uuid.UUID:
    return uuid.uuid5(_ESPACE, f"{HOTEL}:{nature}:{code}")


# --- Points de vente et services -------------------------------------------
# (code, libelle, genre, a la chambre, ouverture, fermeture)
POINTS = [
    ("RESTO", "Restaurant", OutletKind.OUTLET, True, "06:30", "23:00"),
    ("BAR", "Bar / Lounge", OutletKind.OUTLET, True, "10:00", "02:00"),
    ("BOUTIQUE", "Boutique de l'hôtel", OutletKind.OUTLET, True, "08:00", "21:00"),
    ("BOITE_DE_NUIT", "Boîte de nuit", OutletKind.OUTLET, True, "22:00", "05:00"),
    ("ROOM_SERVICE", "Room service", OutletKind.OUTLET, True, None, None),
    ("BAR_PISCINE", "Bar de la piscine", OutletKind.OUTLET, True, "09:00", "20:00"),
    ("CAFE", "Café-pâtisserie", OutletKind.OUTLET, True, "06:00", "20:00"),
    ("SPA", "Spa", OutletKind.SERVICE, True, "09:00", "21:00"),
    ("PISCINE", "Piscine", OutletKind.SERVICE, True, "08:00", "20:00"),
    ("SALLE_SPORT", "Salle de sport", OutletKind.SERVICE, True, "06:00", "22:00"),
    ("FITNESS", "Fitness", OutletKind.SERVICE, True, "07:00", "20:00"),
    ("SALLE_CONFERENCE", "Salle de conférence", OutletKind.SERVICE, True, None, None),
    ("SALLE_BANQUET", "Salle de banquet", OutletKind.SERVICE, True, None, None),
    ("RECEPTION", "Réception", OutletKind.SERVICE, True, None, None),
]

# --- Fournisseurs ------------------------------------------------------------
FOURNISSEURS = [
    ("SABC", "Brasseries du Cameroun (SABC)", "Douala, Koumassi", "+237 233 42 50 00"),
    ("GUINNESS", "Guinness Cameroun", "Douala, Bassa", "+237 233 37 21 00"),
    ("SOURCE_PAYS", "Source du Pays (Supermont)", "Mbanga", "+237 233 39 40 00"),
    ("MOKOLO", "Grossiste du marché Mokolo", "Yaoundé, Mokolo", "+237 677 00 00 00"),
    ("MARCHE_CENTRAL", "Marché central de Douala (vivres frais)", "Douala, Akwa", "+237 699 00 00 00"),
    ("CONGELCAM", "Congelcam (poissons et viandes)", "Douala, Port", "+237 233 40 10 00"),
    ("CHOCOCAM", "Grossiste épicerie Chococam", "Douala, Bassa", "+237 233 37 70 00"),
    ("HYGIENE_PRO", "Hygiène Pro Cameroun", "Yaoundé, Mvan", "+237 222 30 30 30"),
]

# --- Produits : (reference, libelle, categorie, unite, achat, vente, seuil, fournisseur)
CATEGORIES = [
    "Bières", "Sodas", "Eaux", "Jus", "Vins et spiritueux", "Boutique",
    "Épicerie", "Viandes et poissons", "Fruits et légumes", "Produits laitiers et œufs",
    "Café, thé et boulangerie", "Entretien", "Spa et bien-être",
]
PRODUITS = [
    ("MUTZIG", "Mutzig 65 cl", "Bières", "BTL", 450, 1000, 48, "SABC"),
    ("33_EXPORT", "33 Export 65 cl", "Bières", "BTL", 420, 900, 48, "SABC"),
    ("CASTEL", "Castel Beer 65 cl", "Bières", "BTL", 420, 900, 48, "SABC"),
    ("BEAUFORT", "Beaufort Lager 65 cl", "Bières", "BTL", 400, 900, 24, "SABC"),
    ("ISENBECK", "Isenbeck 65 cl", "Bières", "BTL", 450, 1000, 24, "GUINNESS"),
    ("GUINNESS", "Guinness 33 cl", "Bières", "BTL", 500, 1200, 24, "GUINNESS"),
    ("HEINEKEN", "Heineken 33 cl", "Bières", "BTL", 600, 1500, 24, "GUINNESS"),
    ("TOP_ANANAS", "Top Ananas 35 cl", "Sodas", "BTL", 250, 500, 24, "SABC"),
    ("TOP_PAMPLE", "Top Pamplemousse 35 cl", "Sodas", "BTL", 250, 500, 24, "SABC"),
    ("DJINO", "Djino Cocktail 35 cl", "Sodas", "BTL", 300, 600, 24, "SABC"),
    ("COCA", "Coca-Cola 35 cl", "Sodas", "BTL", 300, 700, 24, "SABC"),
    ("VIMTO", "Vimto 35 cl", "Sodas", "BTL", 300, 600, 12, "SABC"),
    ("ORANGINA", "Orangina 33 cl", "Sodas", "BTL", 350, 700, 12, "SABC"),
    ("SUPERMONT", "Supermont 1,5 L", "Eaux", "BTL", 300, 700, 36, "SOURCE_PAYS"),
    ("TANGUI", "Tangui 1,5 L", "Eaux", "BTL", 350, 800, 36, "SABC"),
    ("AQUABELLE", "Aquabelle 1,5 L", "Eaux", "BTL", 300, 700, 24, "MOKOLO"),
    ("JUS_FOLERE", "Jus de foléré maison 50 cl", "Jus", "BTL", 200, 700, 12, "MOKOLO"),
    ("JUS_GINGEMBRE", "Jus de gingembre maison 50 cl", "Jus", "BTL", 200, 700, 12, "MOKOLO"),
    ("JB", "Whisky J&B 75 cl", "Vins et spiritueux", "BTL", 8000, 25000, 4, "MOKOLO"),
    ("VIN_ROUGE", "Vin rouge Baron de Valls 75 cl", "Vins et spiritueux", "BTL", 4000, 12000, 6, "MOKOLO"),
    ("MOET", "Champagne Moët & Chandon 75 cl", "Vins et spiritueux", "BTL", 35000, 90000, 2, "MOKOLO"),
    ("SAVON", "Savon de toilette", "Boutique", "U", 300, 800, 20, "MOKOLO"),
    ("DENTIFRICE", "Dentifrice", "Boutique", "U", 700, 1500, 10, "MOKOLO"),
    ("BROSSE", "Brosse à dents", "Boutique", "U", 400, 1000, 10, "MOKOLO"),
    ("SERVIETTE", "Serviette de bain", "Boutique", "U", 3000, 7000, 5, "MOKOLO"),
    ("TSHIRT", "Tee-shirt souvenir Edge Hotel", "Boutique", "U", 3000, 8000, 5, "MOKOLO"),
    ("PAGNE", "Pagne souvenir", "Boutique", "U", 4000, 10000, 5, "MOKOLO"),
    # L'economat ne tient pas que des boissons : tout ce que l'hotel achete
    # pour vendre ou pour servir y entre d'abord.
    ("RIZ", "Riz parfumé", "Épicerie", "KG", 700, 0, 50, "CHOCOCAM"),
    ("HUILE_VEG", "Huile végétale raffinée", "Épicerie", "L", 1300, 0, 20, "CHOCOCAM"),
    ("HUILE_PALME", "Huile de palme rouge", "Épicerie", "L", 1000, 0, 20, "MARCHE_CENTRAL"),
    ("FARINE", "Farine de blé", "Épicerie", "KG", 650, 0, 25, "CHOCOCAM"),
    ("SUCRE", "Sucre en poudre", "Épicerie", "KG", 800, 0, 20, "CHOCOCAM"),
    ("SEL", "Sel fin", "Épicerie", "KG", 300, 0, 10, "CHOCOCAM"),
    ("ARACHIDES", "Arachides crues", "Épicerie", "KG", 1200, 0, 10, "MARCHE_CENTRAL"),
    ("EGUSI", "Graines de courge (egusi)", "Épicerie", "KG", 2500, 0, 5, "MARCHE_CENTRAL"),
    ("EPICES_MBONGO", "Épices mbongo", "Épicerie", "KG", 4000, 0, 2, "MARCHE_CENTRAL"),
    ("CUBES", "Bouillon en cubes (boîte)", "Épicerie", "U", 1500, 0, 5, "CHOCOCAM"),
    ("POULET", "Poulet entier", "Viandes et poissons", "U", 4000, 0, 20, "MARCHE_CENTRAL"),
    ("BOEUF", "Viande de bœuf", "Viandes et poissons", "KG", 3500, 0, 15, "CONGELCAM"),
    ("CHEVRE", "Viande de chèvre", "Viandes et poissons", "KG", 4500, 0, 10, "MARCHE_CENTRAL"),
    ("POISSON_BAR", "Poisson bar", "Viandes et poissons", "KG", 3000, 0, 15, "CONGELCAM"),
    ("CREVETTES", "Crevettes", "Viandes et poissons", "KG", 6000, 0, 5, "CONGELCAM"),
    ("FEUILLES_NDOLE", "Feuilles de ndolé lavées", "Fruits et légumes", "KG", 1500, 0, 10, "MARCHE_CENTRAL"),
    ("FEUILLES_ERU", "Feuilles d'eru (okok)", "Fruits et légumes", "KG", 2000, 0, 5, "MARCHE_CENTRAL"),
    ("PLANTAIN", "Plantain (régime)", "Fruits et légumes", "U", 3000, 0, 10, "MARCHE_CENTRAL"),
    ("MANIOC", "Bâton de manioc", "Fruits et légumes", "U", 150, 0, 40, "MARCHE_CENTRAL"),
    ("MIONDO", "Miondo (paquet)", "Fruits et légumes", "U", 500, 0, 20, "MARCHE_CENTRAL"),
    ("TARO", "Taro", "Fruits et légumes", "KG", 800, 0, 10, "MARCHE_CENTRAL"),
    ("OIGNONS", "Oignons", "Fruits et légumes", "KG", 600, 0, 15, "MARCHE_CENTRAL"),
    ("TOMATES", "Tomates", "Fruits et légumes", "KG", 700, 0, 15, "MARCHE_CENTRAL"),
    ("AIL", "Ail", "Fruits et légumes", "KG", 2500, 0, 3, "MARCHE_CENTRAL"),
    ("PIMENT", "Piment", "Fruits et légumes", "KG", 1500, 0, 3, "MARCHE_CENTRAL"),
    ("AVOCATS", "Avocats", "Fruits et légumes", "U", 150, 0, 30, "MARCHE_CENTRAL"),
    ("FRUITS", "Fruits de saison (ananas, papaye, mangue)", "Fruits et légumes", "KG", 600, 0, 20, "MARCHE_CENTRAL"),
    ("OEUFS", "Œufs (plateau de 30)", "Produits laitiers et œufs", "U", 2500, 0, 5, "MARCHE_CENTRAL"),
    ("LAIT", "Lait entier", "Produits laitiers et œufs", "L", 1000, 0, 20, "CHOCOCAM"),
    ("BEURRE", "Beurre", "Produits laitiers et œufs", "KG", 5000, 0, 3, "CHOCOCAM"),
    ("CAFE_GRAINS", "Café arabica de l'Ouest en grains", "Café, thé et boulangerie", "KG", 4000, 0, 5, "MOKOLO"),
    ("THE", "Thé (boîte de 100 sachets)", "Café, thé et boulangerie", "U", 2500, 0, 3, "CHOCOCAM"),
    ("CHOCOLAT", "Poudre de cacao", "Café, thé et boulangerie", "KG", 3000, 0, 3, "CHOCOCAM"),
    ("PAIN", "Pain (baguette)", "Café, thé et boulangerie", "U", 150, 0, 40, "MARCHE_CENTRAL"),
    ("LIQUIDE_VAISSELLE", "Liquide vaisselle", "Entretien", "L", 900, 0, 10, "HYGIENE_PRO"),
    ("JAVEL", "Eau de Javel", "Entretien", "L", 500, 0, 10, "HYGIENE_PRO"),
    ("PAPIER_TOILETTE", "Papier toilette (rouleau)", "Entretien", "U", 250, 0, 60, "HYGIENE_PRO"),
    ("SACS_POUBELLE", "Sacs poubelle (rouleau)", "Entretien", "U", 1500, 0, 10, "HYGIENE_PRO"),
    ("HUILE_MASSAGE", "Huile de massage karité", "Spa et bien-être", "L", 6000, 0, 3, "MOKOLO"),
    ("SERVIETTE_SPA", "Serviette de spa", "Spa et bien-être", "U", 2500, 0, 20, "MOKOLO"),
]

# --- Stock : entree a l'economat, puis ravitaillements valides ---------------
ENTREES = {
    "MUTZIG": 240, "33_EXPORT": 192, "CASTEL": 192, "BEAUFORT": 96, "ISENBECK": 96,
    "GUINNESS": 120, "HEINEKEN": 96, "TOP_ANANAS": 120, "TOP_PAMPLE": 96, "DJINO": 96,
    "COCA": 120, "VIMTO": 48, "ORANGINA": 48, "SUPERMONT": 144, "TANGUI": 144,
    "AQUABELLE": 72, "JUS_FOLERE": 40, "JUS_GINGEMBRE": 40, "JB": 12, "VIN_ROUGE": 24,
    "MOET": 6, "SAVON": 60, "DENTIFRICE": 30, "BROSSE": 30, "SERVIETTE": 15,
    "TSHIRT": 20, "PAGNE": 15,
    "RIZ": 200, "HUILE_VEG": 60, "HUILE_PALME": 40, "FARINE": 100, "SUCRE": 80, "SEL": 20,
    "ARACHIDES": 30, "EGUSI": 15, "EPICES_MBONGO": 5, "CUBES": 20, "POULET": 60, "BOEUF": 50,
    "CHEVRE": 30, "POISSON_BAR": 50, "CREVETTES": 20, "FEUILLES_NDOLE": 30, "FEUILLES_ERU": 15,
    "PLANTAIN": 30, "MANIOC": 150, "MIONDO": 60, "TARO": 30, "OIGNONS": 40, "TOMATES": 40,
    "AIL": 5, "PIMENT": 5, "AVOCATS": 80, "FRUITS": 50, "OEUFS": 20, "LAIT": 60, "BEURRE": 10,
    "CAFE_GRAINS": 15, "THE": 10, "CHOCOLAT": 8, "PAIN": 120, "LIQUIDE_VAISSELLE": 30,
    "JAVEL": 30, "PAPIER_TOILETTE": 240, "SACS_POUBELLE": 30, "HUILE_MASSAGE": 10,
    "SERVIETTE_SPA": 60,
}

# La cuisine : un magasin interne, pas un point de vente. L'economat la
# ravitaille en denrees ; c'est elle qui prepare les plats du restaurant, du
# room service et du bar.
CUISINE = ("CUISINE", "Cuisine")
# (produit, point de vente, quantite)
RAVITAILLEMENTS = [
    ("MUTZIG", "BAR", 48), ("MUTZIG", "RESTO", 24), ("MUTZIG", "BOITE_DE_NUIT", 72),
    ("MUTZIG", "BAR_PISCINE", 24), ("33_EXPORT", "BAR", 36), ("33_EXPORT", "BOITE_DE_NUIT", 36),
    ("CASTEL", "BAR", 36), ("CASTEL", "RESTO", 12), ("GUINNESS", "BAR", 24),
    ("GUINNESS", "BOITE_DE_NUIT", 36), ("HEINEKEN", "BOITE_DE_NUIT", 36), ("HEINEKEN", "BAR", 24),
    ("ISENBECK", "BAR", 24), ("BEAUFORT", "BAR", 24),
    ("TOP_ANANAS", "BAR", 24), ("TOP_ANANAS", "RESTO", 24), ("TOP_PAMPLE", "RESTO", 24),
    ("DJINO", "BAR", 24), ("COCA", "BAR", 24), ("COCA", "BOITE_DE_NUIT", 24), ("COCA", "RESTO", 24),
    ("SUPERMONT", "RESTO", 36), ("SUPERMONT", "BAR", 24), ("SUPERMONT", "ROOM_SERVICE", 24),
    ("TANGUI", "RESTO", 24), ("TANGUI", "BAR_PISCINE", 24), ("JUS_FOLERE", "RESTO", 12),
    ("JUS_FOLERE", "CAFE", 12), ("JUS_GINGEMBRE", "CAFE", 12), ("JB", "BOITE_DE_NUIT", 6),
    ("MOET", "BOITE_DE_NUIT", 4), ("VIN_ROUGE", "RESTO", 12),
    ("SAVON", "BOUTIQUE", 30), ("DENTIFRICE", "BOUTIQUE", 15), ("BROSSE", "BOUTIQUE", 15),
    ("SERVIETTE", "BOUTIQUE", 8), ("TSHIRT", "BOUTIQUE", 10), ("PAGNE", "BOUTIQUE", 8),
    # La cuisine recoit les denrees.
    ("RIZ", "CUISINE", 50), ("HUILE_VEG", "CUISINE", 15), ("HUILE_PALME", "CUISINE", 10),
    ("FARINE", "CUISINE", 20), ("SUCRE", "CUISINE", 10), ("SEL", "CUISINE", 5),
    ("ARACHIDES", "CUISINE", 10), ("EGUSI", "CUISINE", 5), ("EPICES_MBONGO", "CUISINE", 2),
    ("CUBES", "CUISINE", 5), ("POULET", "CUISINE", 20), ("BOEUF", "CUISINE", 15),
    ("CHEVRE", "CUISINE", 10), ("POISSON_BAR", "CUISINE", 15), ("CREVETTES", "CUISINE", 6),
    ("FEUILLES_NDOLE", "CUISINE", 10), ("FEUILLES_ERU", "CUISINE", 5), ("PLANTAIN", "CUISINE", 10),
    ("MANIOC", "CUISINE", 40), ("MIONDO", "CUISINE", 20), ("TARO", "CUISINE", 10),
    ("OIGNONS", "CUISINE", 15), ("TOMATES", "CUISINE", 15), ("AIL", "CUISINE", 2),
    ("PIMENT", "CUISINE", 2), ("AVOCATS", "CUISINE", 30), ("FRUITS", "CUISINE", 15),
    ("OEUFS", "CUISINE", 6), ("LAIT", "CUISINE", 10), ("BEURRE", "CUISINE", 3),
    # Le cafe, ses boissons chaudes ; le spa, ses huiles et serviettes ; le
    # menage passe par la reception pour l'entretien.
    ("CAFE_GRAINS", "CAFE", 5), ("THE", "CAFE", 4), ("CHOCOLAT", "CAFE", 3), ("LAIT", "CAFE", 15),
    ("PAIN", "CAFE", 30), ("SUCRE", "CAFE", 5), ("OEUFS", "ROOM_SERVICE", 2),
    ("HUILE_MASSAGE", "SPA", 4), ("SERVIETTE_SPA", "SPA", 30), ("SERVIETTE_SPA", "PISCINE", 20),
    ("LIQUIDE_VAISSELLE", "CUISINE", 8), ("JAVEL", "RECEPTION", 10),
    ("PAPIER_TOILETTE", "RECEPTION", 80), ("SACS_POUBELLE", "CUISINE", 8),
]

# --- Cartes : point de vente -> [(categorie, [(code, libelle, prix, produit)])]
# Le produit relie une boisson a son stock : la vendre fait baisser le stock du
# point de vente. Un plat, une prestation n'en ont pas.
def _boissons(prefixe: str, prix_biere: int) -> list[tuple]:
    return [
        ("Bières", [
            (f"{prefixe}_MUTZIG", "Mutzig", prix_biere, "MUTZIG"),
            (f"{prefixe}_33", "33 Export", prix_biere - 100, "33_EXPORT"),
            (f"{prefixe}_CASTEL", "Castel Beer", prix_biere - 100, "CASTEL"),
            (f"{prefixe}_GUINNESS", "Guinness", prix_biere + 200, "GUINNESS"),
        ]),
        ("Sodas et eaux", [
            (f"{prefixe}_TOP", "Top Ananas", 600, "TOP_ANANAS"),
            (f"{prefixe}_COCA", "Coca-Cola", 800, "COCA"),
            (f"{prefixe}_SUPERMONT", "Supermont 1,5 L", 1000, "SUPERMONT"),
        ]),
    ]


CARTES = {
    "RESTO": [
        ("Entrées", [
            ("R_AVOCAT", "Salade d'avocat", 2500, None),
            ("R_SOYA", "Brochettes de soya", 2000, None),
            ("R_BEIGNETS_HARICOTS", "Beignets haricots et bouillie", 1500, None),
        ]),
        ("Plats camerounais", [
            ("R_NDOLE", "Ndolé crevettes et plantain", 6500, None),
            ("R_POULET_DG", "Poulet DG", 7500, None),
            ("R_ERU", "Eru et water fufu", 5000, None),
            ("R_KOKI", "Koki et plantain", 4000, None),
            ("R_ACHU", "Achu sauce jaune", 5500, None),
            ("R_MBONGO", "Mbongo tchobi de poisson", 6500, None),
            ("R_OKOK", "Okok et bâton de manioc", 4500, None),
            ("R_POISSON_BRAISE", "Poisson braisé et miondo", 7000, None),
            ("R_SANGA", "Sanga", 4000, None),
            ("R_KONDRE", "Kondre de chèvre", 6000, None),
            ("R_TARO", "Taro sauce jaune", 5000, None),
        ]),
        ("Accompagnements", [
            ("R_PLANTAIN", "Plantain mûr frit", 1000, None),
            ("R_MIONDO", "Miondo", 500, None),
            ("R_BOBOLO", "Bobolo", 500, None),
            ("R_RIZ", "Riz blanc", 1000, None),
            ("R_FRITES", "Frites de patate douce", 1000, None),
        ]),
        ("Desserts", [
            ("R_FRUITS", "Salade de fruits", 2000, None),
            ("R_BEIGNETS_COCO", "Beignets coco", 1000, None),
        ]),
        ("Boissons", [
            ("R_MUTZIG", "Mutzig", 1200, "MUTZIG"),
            ("R_CASTEL", "Castel Beer", 1100, "CASTEL"),
            ("R_TOP", "Top Ananas", 700, "TOP_ANANAS"),
            ("R_COCA", "Coca-Cola", 900, "COCA"),
            ("R_SUPERMONT", "Supermont 1,5 L", 1000, "SUPERMONT"),
            ("R_FOLERE", "Jus de foléré", 1000, "JUS_FOLERE"),
            ("R_VIN", "Vin rouge (bouteille)", 15000, "VIN_ROUGE"),
        ]),
    ],
    "BAR": _boissons("B", 1000) + [
        ("Cocktails", [
            ("B_MOJITO", "Mojito", 3500, None),
            ("B_FOLERE_COCKTAIL", "Cocktail foléré gingembre", 2500, None),
        ]),
        ("Grignotages", [
            ("B_SOYA", "Brochettes de soya", 2000, None),
            ("B_ARACHIDES", "Arachides grillées", 500, None),
            ("B_CHIPS", "Chips de plantain", 500, None),
        ]),
    ],
    "BOITE_DE_NUIT": _boissons("N", 1500) + [
        ("Bouteilles", [
            ("N_JB", "Whisky J&B (bouteille)", 25000, "JB"),
            ("N_MOET", "Champagne Moët & Chandon", 90000, "MOET"),
            ("N_HEINEKEN", "Heineken", 2000, "HEINEKEN"),
        ]),
        ("Entrées", [
            ("N_ENTREE", "Droit d'entrée", 5000, None),
            ("N_VIP", "Table VIP (soirée)", 50000, None),
        ]),
    ],
    "BAR_PISCINE": [
        ("Boissons", [
            ("P_MUTZIG", "Mutzig", 1000, "MUTZIG"),
            ("P_TANGUI", "Tangui 1,5 L", 1000, "TANGUI"),
            ("P_COCKTAIL", "Cocktail sans alcool", 2000, None),
        ]),
        ("Snacks", [
            ("P_SANDWICH", "Sandwich poulet", 2500, None),
            ("P_FRITES", "Frites de plantain", 1500, None),
        ]),
    ],
    "ROOM_SERVICE": [
        ("Plats", [
            ("RS_POULET_DG", "Poulet DG", 8500, None),
            ("RS_NDOLE", "Ndolé crevettes et plantain", 7500, None),
            ("RS_OMELETTE", "Omelette et pain", 2500, None),
        ]),
        ("Boissons", [
            ("RS_SUPERMONT", "Supermont 1,5 L", 1200, "SUPERMONT"),
        ]),
    ],
    "CAFE": [
        ("Boissons chaudes", [
            ("C_CAFE", "Café arabica de l'Ouest", 1000, None),
            ("C_THE", "Thé", 800, None),
            ("C_CHOCOLAT", "Chocolat chaud", 1200, None),
        ]),
        ("Viennoiseries", [
            ("C_CROISSANT", "Croissant", 700, None),
            ("C_PAIN_CHOCO", "Pain au chocolat", 800, None),
            ("C_GATEAU", "Part de gâteau", 1500, None),
            ("C_BEIGNETS", "Beignets (sachet)", 500, None),
        ]),
        ("Jus", [
            ("C_FOLERE", "Jus de foléré", 1000, "JUS_FOLERE"),
            ("C_GINGEMBRE", "Jus de gingembre", 1000, "JUS_GINGEMBRE"),
        ]),
    ],
    "BOUTIQUE": [
        ("Hygiène", [
            ("BQ_SAVON", "Savon de toilette", 800, "SAVON"),
            ("BQ_DENTIFRICE", "Dentifrice", 1500, "DENTIFRICE"),
            ("BQ_BROSSE", "Brosse à dents", 1000, "BROSSE"),
        ]),
        ("Linge et souvenirs", [
            ("BQ_SERVIETTE", "Serviette de bain", 7000, "SERVIETTE"),
            ("BQ_TSHIRT", "Tee-shirt Edge Hotel", 8000, "TSHIRT"),
            ("BQ_PAGNE", "Pagne souvenir", 10000, "PAGNE"),
        ]),
    ],
    "SPA": [
        ("Soins", [
            ("S_MASSAGE", "Massage relaxant 1 h", 20000, None),
            ("S_MASSAGE_DUO", "Massage duo 1 h", 35000, None),
            ("S_HAMMAM", "Hammam", 10000, None),
            ("S_VISAGE", "Soin du visage", 15000, None),
        ]),
    ],
    "PISCINE": [
        ("Accès", [
            ("PI_JOURNEE", "Accès journée (non-résident)", 3000, None),
            ("PI_ENFANT", "Accès journée enfant", 1500, None),
            ("PI_SERVIETTE", "Location de serviette", 1000, None),
        ]),
    ],
    "SALLE_SPORT": [
        ("Accès", [
            ("SS_JOURNEE", "Accès journée", 3000, None),
            ("SS_MOIS", "Abonnement mensuel", 25000, None),
        ]),
    ],
    "FITNESS": [
        ("Séances", [
            ("F_COACHING", "Séance de coaching", 5000, None),
            ("F_COLLECTIF", "Cours collectif", 2500, None),
            ("F_YOGA", "Séance de yoga", 3000, None),
        ]),
    ],
    "SALLE_CONFERENCE": [
        ("Location", [
            ("SC_DEMI", "Salle demi-journée", 75000, None),
            ("SC_JOURNEE", "Salle journée", 120000, None),
            ("SC_PROJECTEUR", "Vidéoprojecteur et sonorisation", 15000, None),
            ("SC_PAUSE", "Pause-café (par personne)", 2500, None),
        ]),
    ],
    "SALLE_BANQUET": [
        ("Location", [
            ("SB_SOIREE", "Location soirée", 250000, None),
            ("SB_COCKTAIL", "Forfait cocktail (par personne)", 8000, None),
            ("SB_DINER", "Forfait dîner (par personne)", 15000, None),
        ]),
    ],
    "RECEPTION": [
        ("Prestations", [
            ("RC_BLANCHISSERIE", "Blanchisserie (chemise)", 1500, None),
            ("RC_TRANSFERT", "Transfert aéroport", 15000, None),
            ("RC_TAXI", "Réservation de taxi", 1000, None),
            ("RC_IMPRESSION", "Impression (page)", 200, None),
        ]),
    ],
}


async def _upsert(session: AsyncSession, modele, id_: uuid.UUID, **champs):
    """Cree la ligne, ou met ses champs a jour si elle existe deja."""
    ligne = await session.get(modele, id_)
    if ligne is None:
        ligne = modele(id=id_, **champs)
        session.add(ligne)
    else:
        for cle, valeur in champs.items():
            setattr(ligne, cle, valeur)
    await session.flush()
    return ligne


def _heure(hhmm: str | None) -> dt.time | None:
    return None if hhmm is None else dt.time.fromisoformat(hhmm)


async def charger(session: AsyncSession) -> dict[str, int]:
    compte = {"points": 0, "produits": 0, "articles": 0, "mouvements": 0}

    # Points de vente et services. Un point de vente cree a la main avec le
    # meme code est repris : son id reste le sien.
    points: dict[str, Outlet] = {}
    for ordre, (code, label, genre, chambre, ouvre, ferme) in enumerate(POINTS):
        existant = await session.scalar(
            select(Outlet).where(Outlet.hotel_id == HOTEL, Outlet.code == code)
        )
        id_ = existant.id if existant is not None else _id("outlet", code)
        points[code] = await _upsert(
            session, Outlet, id_,
            hotel_id=HOTEL, code=code, label=label, kind=genre,
            allows_room_charge=chambre, opens_at=_heure(ouvre), closes_at=_heure(ferme),
            sort_order=ordre, is_active=True,
        )
        compte["points"] += 1

    economat = await ensure_central(session, HOTEL)
    magasins = {code: await ensure_outlet_location(session, o) for code, o in points.items()}
    for code, magasin in magasins.items():
        magasin.label = points[code].label
        # Les magasins des points de vente d'abord, ceux des services ensuite.
        magasin.sort_order = (
            100 if points[code].kind == OutletKind.SERVICE else 10
        ) + points[code].sort_order
    code_cuisine, label_cuisine = CUISINE
    existante = await session.scalar(
        select(StockLocation).where(
            StockLocation.hotel_id == HOTEL, StockLocation.code == code_cuisine
        )
    )
    magasins[code_cuisine] = await _upsert(
        session, StockLocation,
        existante.id if existante is not None else _id("stock_location", code_cuisine),
        hotel_id=HOTEL, code=code_cuisine, label=label_cuisine, sort_order=1,
    )
    points_et_cuisine = {**{c: o.label for c, o in points.items()}, code_cuisine: label_cuisine}

    fournisseurs = {}
    for code, nom, adresse, tel in FOURNISSEURS:
        fournisseurs[code] = await _upsert(
            session, Supplier, _id("supplier", code),
            hotel_id=HOTEL, code=code, name=nom, address=adresse, phone=tel,
        )

    categories = {}
    for ordre, label in enumerate(CATEGORIES):
        categories[label] = await _upsert(
            session, ProductCategory, _id("product_category", label),
            hotel_id=HOTEL, label=label, sort_order=ordre,
        )

    produits = {}
    for ref, label, cat, unite, achat, vente, seuil, fourn in PRODUITS:
        produits[ref] = await _upsert(
            session, Product, _id("product", ref),
            hotel_id=HOTEL, reference=ref, label=label, category_id=categories[cat].id,
            unit=unite, purchase_price=achat, sale_price=vente, min_stock=seuil,
            is_sellable=True, default_supplier_id=fournisseurs[fourn].id,
        )
        compte["produits"] += 1

    # Les mouvements : identifiants fixes, jamais rejoues.
    maintenant = dt.datetime.now(dt.timezone.utc)

    async def mouvement(cle: str, **champs) -> None:
        id_ = _id("stock_movement", cle)
        if await session.get(StockMovement, id_) is not None:
            return
        m = StockMovement(
            id=id_, hotel_id=HOTEL, moved_at=maintenant, moved_by=DEMO_ADMIN, **champs,
        )
        session.add(m)
        await session.flush()
        await apply_movement(session, m)
        compte["mouvements"] += 1

    for ref, quantite in ENTREES.items():
        p = produits[ref]
        await mouvement(
            f"entree:{ref}", product_id=p.id, stock_location_id=economat.id,
            type=StockMovementType.IN, quantity=quantite, unit_cost=p.purchase_price,
            supplier_id=p.default_supplier_id, reason="Stock initial (données d'essai)",
            status=StockMovementStatus.APPROVED,
        )
    for ref, code, quantite in RAVITAILLEMENTS:
        await mouvement(
            f"transfert:{ref}:{code}", product_id=produits[ref].id,
            stock_location_id=economat.id, counterpart_location_id=magasins[code].id,
            type=StockMovementType.TRANSFER, quantity=quantite,
            reason=f"Ravitaillement {points_et_cuisine[code]}",
            status=StockMovementStatus.APPROVED, decided_by=DEMO_ADMIN, decided_at=maintenant,
        )

    # Les cartes : une categorie par point de vente.
    for code, rubriques in CARTES.items():
        for ordre, (rubrique, articles) in enumerate(rubriques):
            categorie = await _upsert(
                session, MenuCategory, _id("menu_category", f"{code}:{rubrique}"),
                hotel_id=HOTEL, outlet_id=points[code].id, label=rubrique, sort_order=ordre,
            )
            for code_article, label, prix, ref in articles:
                await _upsert(
                    session, MenuItem, _id("menu_item", code_article),
                    hotel_id=HOTEL, code=code_article, label=label,
                    menu_category_id=categorie.id, price=prix, is_available=True,
                    product_id=produits[ref].id if ref else None, stock_quantity=1,
                )
                compte["articles"] += 1

    await session.commit()
    return compte


async def main() -> None:
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        compte = await charger(session)
    await engine.dispose()
    print(
        f"{compte['points']} points de vente et services, {compte['produits']} produits, "
        f"{compte['articles']} articles de carte, {compte['mouvements']} mouvements de stock "
        "(0 au second passage : deja charges)."
    )


if __name__ == "__main__":
    asyncio.run(main())
