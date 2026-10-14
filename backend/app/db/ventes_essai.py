"""Ventes d'essai : trente jours de comptoir, pour que les ecrans Ventes, Ma
caisse, Stocks et Rapports aient de quoi montrer.

Le jeu de `donnees_essai.py` pose les points de vente, les cartes et le stock
de depart ; il ne vend rien. Celui-ci vend, chaque jour des trente derniers,
dans chaque point de vente et service, aux heures ou ils travaillent (le bar
le soir, la boite de nuit du jeudi au samedi apres minuit, la piscine
l'apres-midi), avec un chiffre qui monte doucement d'une semaine a l'autre :
la comparaison a la periode precedente a quelque chose a dire.

Avec les ventes vient tout ce qu'elles entrainent, comme a la tablette :
- un tiroir par point de vente et par jour, ferme le soir avec parfois un
  petit ecart, et verse a la reception (la caisse centrale) qui confirme ce
  qu'elle recoit ; hier, deux versements attendent encore la reception ;
- aujourd'hui, les tiroirs restent ouverts, et la derniere ardoise du cafe,
  du restaurant et du bar n'est pas encore payee ;
- la sortie de stock de chaque article vendu, a son cout du jour ;
- des achats chaque semaine a l'economat, a des prix qui montent un peu
  (le cout moyen et la marge bougent), et le ravitaillement des points de
  vente et de la cuisine ;
- ce qui est utilise sans etre vendu : les ingredients de la cuisine, les
  produits d'entretien des chambres, l'huile du spa ;
- deux bieres du bar sous leur seuil, et une demande de transfert qui attend
  sa validation ;
- les depenses du mois hors stock (salaires, electricite, eau, carburant du
  groupe...), dont une annulee : le benefice des Rapports retranche les
  unes et ignore l'autre.

Trois agents de comptoir tiennent les tiroirs (COMPTOIR01, COMPTOIR02,
SERVICES01 ; mot de passe et PIN des comptes de demonstration). La reception
(RECEP01) tient la caisse centrale et le comptoir de la reception.

**Rejouable** : chaque ligne a un identifiant fixe. Un jour deja charge pour
un point de vente n'est jamais recharge ; relance un autre jour, le script
ajoute les jours manquants et clot ceux qu'il avait laisses ouverts.

    cd backend
    python -m app.db.seed
    python -m app.db.donnees_essai
    python -m app.db.ventes_essai
"""

from __future__ import annotations

import asyncio
import datetime as dt
import math
import random
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.api.v1.cash_sessions import _expected_cash
from app.core.config import settings
from app.core.security import hash_secret
from app.db.seed import DEMO_ADMIN, DEMO_ADMIN_PASSWORD, DEMO_PIN, DEMO_RECEPTION, HOTEL
from app.models import (
    CashSession,
    Expense,
    Folio,
    FolioItem,
    Hotel,
    MenuCategory,
    MenuItem,
    Outlet,
    Payment,
    Product,
    Role,
    StockLevel,
    StockLocation,
    StockMovement,
    User,
    UserOutlet,
    UserRole,
)
from app.models.enums import (
    CashSessionStatus,
    ChargeCategory,
    ExpenseCategory,
    FolioStatus,
    FolioType,
    PaymentMethod,
    StockMovementStatus,
    StockMovementType,
)
from app.services.business_day import business_date_for
from app.services.costing import record_entry_cost, unit_cost_of
from app.services.folios import recompute_totals
from app.services.numbering import Scope, next_number
from app.services.stock_levels import apply_movement, deduct_for_sale
from app.services.stock_locations import ensure_central

JOURS = 30

# Un espace a part de celui de `donnees_essai.py` : les deux jeux ne se
# marchent jamais dessus.
_ESPACE = uuid.UUID("3a7e9c41-52b8-4d0f-9e6a-7b1c2d3e4f50")


def _id(nature: str, cle: str) -> uuid.UUID:
    return uuid.uuid5(_ESPACE, f"{HOTEL}:{nature}:{cle}")


# --- Les agents de comptoir ---------------------------------------------------

# (code, prenom, nom, points de vente). RECEP01 tient le comptoir de la
# reception : il existe deja.
AGENTS = [
    ("COMPTOIR01", "Serge", "Mbarga", ["BAR", "BOITE_DE_NUIT", "BAR_PISCINE"]),
    ("COMPTOIR02", "Clarisse", "Ngo Bassa", ["RESTO", "CAFE", "BOUTIQUE"]),
    (
        "SERVICES01",
        "Brice",
        "Fotso",
        ["SPA", "PISCINE", "SALLE_SPORT", "FITNESS", "SALLE_CONFERENCE", "SALLE_BANQUET"],
    ),
]


# --- Comment chaque point de vente travaille ----------------------------------


@dataclass(frozen=True)
class Profil:
    agent: str
    # Ventes un jour ordinaire ; sous 1, la probabilite d'en faire une.
    ventes: float
    heures: list[tuple[int, int]]
    fond: int = 10000
    forts: frozenset[int] = frozenset({5, 6})
    facteur_fort: float = 1.4
    # Jours d'ouverture (0 = lundi) ; vide, tous les jours.
    jours: frozenset[int] = field(default_factory=frozenset)
    lignes: int = 3
    quantite: int = 2


PROFILS: dict[str, Profil] = {
    "RESTO": Profil(
        "COMPTOIR02", 9,
        [(7, 2), (8, 3), (9, 1), (12, 4), (13, 5), (14, 2), (19, 3), (20, 5), (21, 3)],
        fond=30000,
    ),
    "CAFE": Profil(
        "COMPTOIR02", 7, [(7, 4), (8, 4), (10, 2), (11, 1), (15, 2), (16, 3), (17, 1)],
        fond=15000, facteur_fort=1.2,
    ),
    "BOUTIQUE": Profil(
        "COMPTOIR02", 3, [(10, 1), (12, 1), (15, 1), (18, 2), (19, 1)],
        fond=10000, facteur_fort=1.5, lignes=2,
    ),
    "BAR": Profil(
        "COMPTOIR01", 12,
        [(12, 1), (17, 2), (18, 3), (19, 4), (20, 4), (21, 5), (22, 4), (23, 3), (0, 2), (1, 1)],
        fond=30000, forts=frozenset({4, 5}), facteur_fort=1.6, quantite=4,
    ),
    # Ouverte du jeudi au samedi ; la nuit appartient a la journee hoteliere
    # de la veille (la journee commence a 6 h).
    "BOITE_DE_NUIT": Profil(
        "COMPTOIR01", 10, [(22, 2), (23, 4), (0, 5), (1, 5), (2, 4), (3, 2)],
        fond=50000, forts=frozenset({4, 5}), facteur_fort=2.0,
        jours=frozenset({3, 4, 5}), quantite=4,
    ),
    "BAR_PISCINE": Profil(
        "COMPTOIR01", 5, [(11, 2), (12, 3), (13, 3), (15, 4), (16, 4), (17, 2)],
        fond=15000, facteur_fort=1.8, quantite=3,
    ),
    "SPA": Profil(
        "SERVICES01", 3, [(10, 2), (11, 2), (14, 3), (15, 3), (16, 3), (17, 2), (18, 1)],
        fond=0, facteur_fort=1.5, lignes=1, quantite=1,
    ),
    "PISCINE": Profil(
        "SERVICES01", 6, [(10, 2), (11, 3), (13, 3), (14, 4), (15, 4), (16, 3)],
        fond=10000, facteur_fort=2.0, lignes=1, quantite=3,
    ),
    "SALLE_SPORT": Profil(
        "SERVICES01", 3, [(6, 3), (7, 3), (12, 1), (18, 4), (19, 3)],
        fond=5000, facteur_fort=0.8, lignes=1, quantite=1,
    ),
    "FITNESS": Profil(
        "SERVICES01", 2, [(7, 2), (9, 2), (17, 3), (18, 3)],
        fond=5000, facteur_fort=1.0, lignes=1, quantite=1,
    ),
    "SALLE_CONFERENCE": Profil(
        "SERVICES01", 0.35, [(9, 1)], fond=0,
        jours=frozenset({0, 1, 2, 3, 4}), lignes=1, quantite=1,
    ),
    "SALLE_BANQUET": Profil(
        "SERVICES01", 0.5, [(18, 1)], fond=0, jours=frozenset({5, 6}), lignes=1, quantite=1,
    ),
    "RECEPTION": Profil(
        "RECEP01", 3, [(8, 2), (10, 2), (14, 2), (17, 2), (19, 1)], fond=10000, lignes=1,
    ),
}

# Hier soir, ces versements ne sont pas encore arrives a la reception. Deux
# points de vente ouverts tous les jours : quel que soit le jour du
# chargement, ils ont travaille la veille.
VERSEMENTS_EN_ATTENTE = {"BAR", "RESTO"}

# Aujourd'hui, la derniere ardoise de chacun reste a payer : ouverts des le
# matin, ils ont deja servi a toute heure du chargement.
ARDOISES_A_PAYER = ("CAFE", "RESTO", "BAR")

# Ce que la cuisine utilise par plat servi au restaurant ou au room service.
CUISINE = {
    "RIZ": 0.25, "HUILE_VEG": 0.05, "HUILE_PALME": 0.04, "POULET": 0.15, "BOEUF": 0.1,
    "POISSON_BAR": 0.1, "PLANTAIN": 0.08, "TOMATES": 0.1, "OIGNONS": 0.1, "PIMENT": 0.02,
    "PAIN": 0.4, "OEUFS": 0.05, "LAIT": 0.05, "CAFE_GRAINS": 0.02, "SUCRE": 0.03,
}
# Ce que les chambres consomment chaque semaine, sorti de l'economat.
MENAGE = {"PAPIER_TOILETTE": 40, "JAVEL": 4, "LIQUIDE_VAISSELLE": 3, "SACS_POUBELLE": 3}
# Une huile de massage pour quatre soins.
SPA_HUILE = ("HUILE_MASSAGE", 0.25)

# Les bieres que le bar laisse descendre sous leur seuil, et celle qu'il
# demande a l'economat aujourd'hui.
SOUS_LE_SEUIL = {("BAR", "MUTZIG"), ("BAR", "33_EXPORT")}
DEMANDE_EN_ATTENTE = ("BAR", "MUTZIG", 48)

MOYENS = [(PaymentMethod.CASH, 55), (PaymentMethod.MOBILE_MONEY, 30), (PaymentMethod.CARD, 15)]


def categorie_pour(code: str) -> ChargeCategory:
    """La regle de la tablette (`OrderRepository._categoriePour`), a la lettre."""
    c = code.upper()
    if "BAR" in c or "RESTAURANT" in c or "NUIT" in c:
        return ChargeCategory.FNB
    if "SPA" in c:
        return ChargeCategory.SPA
    if "MINIBAR" in c:
        return ChargeCategory.MINIBAR
    if "LAUNDRY" in c or "BLANCH" in c:
        return ChargeCategory.LAUNDRY
    return ChargeCategory.MISC


@dataclass
class Vente:
    point: str
    jour: dt.date
    rang: int
    servie: dt.datetime
    payee: dt.datetime
    lignes: list[tuple[MenuItem, int]]
    moyen: PaymentMethod

    @property
    def cle(self) -> str:
        return f"{self.point}:{self.jour}:{self.rang}"


def _choisir(rng: random.Random, poids: list[tuple[object, float]]):
    total = sum(p for _, p in poids)
    x = rng.uniform(0, total)
    for valeur, p in poids:
        x -= p
        if x <= 0:
            return valeur
    return poids[-1][0]


def _instant(jour: dt.date, heure: int, minute: int, zone: ZoneInfo, bascule: int) -> dt.datetime:
    """L'heure d'une vente de cette journee hoteliere : avant la bascule, c'est
    deja le lendemain au calendrier."""
    calendrier = jour + dt.timedelta(days=1) if heure < bascule else jour
    local = dt.datetime.combine(calendrier, dt.time(heure, minute), tzinfo=zone)
    return local.astimezone(dt.timezone.utc)


def planifier(
    jours: list[dt.date],
    cartes: dict[str, list[MenuItem]],
    zone: ZoneInfo,
    bascule: int,
    maintenant: dt.datetime,
) -> list[Vente]:
    """Toutes les ventes, decidees d'avance : le ravitaillement de chaque
    semaine se calcule sur ce qui va s'y vendre. Le hasard est seme par point
    de vente et par jour : relancer donne les memes ventes."""
    ventes: list[Vente] = []
    for i, jour in enumerate(jours):
        tendance = 0.85 + 0.25 * i / max(len(jours) - 1, 1)
        for code, profil in PROFILS.items():
            carte = cartes.get(code)
            if not carte:
                continue
            if profil.jours and jour.weekday() not in profil.jours:
                continue
            rng = random.Random(f"{code}:{jour}")
            facteur = profil.facteur_fort if jour.weekday() in profil.forts else 1.0
            if profil.ventes < 1:
                nombre = 1 if rng.random() < profil.ventes * facteur else 0
            else:
                nombre = round(profil.ventes * facteur * tendance * rng.uniform(0.75, 1.25))
            for rang in range(1, nombre + 1):
                heure = _choisir(rng, [(h, float(p)) for h, p in profil.heures])
                servie = _instant(jour, heure, rng.randrange(60), zone, bascule)
                payee = servie + dt.timedelta(minutes=rng.randint(5, 50))
                if payee > maintenant - dt.timedelta(minutes=5):
                    continue
                # Les articles bon marche se vendent plus souvent.
                nb = min(_choisir(rng, [(1, 55), (2, 30), (3, 15)]), profil.lignes, len(carte))
                pris: list[tuple[MenuItem, int]] = []
                restants = list(carte)
                for _ in range(nb):
                    article = _choisir(rng, [(a, 1 / math.sqrt(max(a.price, 1))) for a in restants])
                    restants.remove(article)
                    plafond = profil.quantite if article.product_id else min(profil.quantite, 2)
                    pris.append((article, rng.randint(1, plafond)))
                total = sum(a.price * q for a, q in pris)
                moyens = MOYENS if total < 50000 else [
                    (PaymentMethod.CARD, 50), (PaymentMethod.MOBILE_MONEY, 40), (PaymentMethod.CASH, 10)
                ]
                ventes.append(
                    Vente(code, jour, rang, servie, payee, pris, _choisir(rng, moyens))
                )
    return ventes


# --- Le chargement ------------------------------------------------------------


async def _agents(session: AsyncSession, points: dict[str, Outlet]) -> dict[str, uuid.UUID]:
    """Les agents de comptoir, rattaches a leurs points de vente."""
    role = await session.scalar(select(Role).where(Role.code == "RESTAURANT"))
    ids = {"RECEP01": DEMO_RECEPTION}
    for code, prenom, nom, rattaches in AGENTS:
        existant = await session.scalar(
            select(User).where(User.hotel_id == HOTEL, User.employee_code == code)
        )
        if existant is None:
            existant = User(
                id=_id("user", code), hotel_id=HOTEL, employee_code=code,
                first_name=prenom, last_name=nom,
                password_hash=hash_secret(DEMO_ADMIN_PASSWORD), pin_hash=hash_secret(DEMO_PIN),
                is_active=True, must_change_password=False,
            )
            session.add(existant)
            await session.flush()
            if role is not None:
                session.add(UserRole(user_id=existant.id, role_id=role.id))
            for point in rattaches:
                if point in points:
                    session.add(UserOutlet(user_id=existant.id, outlet_id=points[point].id))
            await session.flush()
        ids[code] = existant.id
    return ids


async def _cartes(session: AsyncSession, points: dict[str, Outlet]) -> dict[str, list[MenuItem]]:
    cartes: dict[str, list[MenuItem]] = {}
    for code, point in points.items():
        cartes[code] = list(
            (
                await session.scalars(
                    select(MenuItem)
                    .join(MenuCategory, MenuCategory.id == MenuItem.menu_category_id)
                    .where(
                        MenuCategory.outlet_id == point.id,
                        MenuItem.deleted_at.is_(None),
                        MenuItem.is_available.is_(True),
                    )
                    .order_by(MenuItem.code)
                )
            ).all()
        )
    return cartes


class Stock:
    """Les niveaux suivis pendant le chargement, pour decider de chaque achat
    et de chaque ravitaillement avant de l'ecrire."""

    def __init__(self, niveaux: dict[tuple[uuid.UUID, uuid.UUID], int]):
        self.niveaux = defaultdict(int, niveaux)

    def __getitem__(self, cle: tuple[uuid.UUID, uuid.UUID]) -> int:
        return self.niveaux[cle]

    def bouger(self, lieu: uuid.UUID, produit: uuid.UUID, delta: int) -> None:
        self.niveaux[(lieu, produit)] += delta


async def charger(session: AsyncSession) -> dict[str, int]:
    compte = defaultdict(int)
    hotel = await session.get(Hotel, HOTEL)
    zone = ZoneInfo(hotel.timezone)
    bascule = hotel.day_rollover_hour
    maintenant = dt.datetime.now(dt.timezone.utc)
    aujourdhui = business_date_for(maintenant, hotel.timezone, bascule)
    jours = [aujourdhui - dt.timedelta(days=n) for n in range(JOURS, -1, -1)]

    points = {
        o.code: o
        for o in (await session.scalars(
            select(Outlet).where(Outlet.hotel_id == HOTEL, Outlet.deleted_at.is_(None))
        )).all()
    }
    manquants = [code for code in PROFILS if code not in points]
    if len(manquants) == len(PROFILS):
        raise SystemExit(
            "Aucun point de vente du jeu d'essai : lancez d'abord python -m app.db.donnees_essai."
        )
    agents = await _agents(session, points)
    cartes = await _cartes(session, points)
    produits = {
        p.reference: p
        for p in (await session.scalars(select(Product).where(Product.hotel_id == HOTEL))).all()
    }
    economat = await ensure_central(session, HOTEL)
    lieux = {
        lieu.code: lieu
        for lieu in (await session.scalars(
            select(StockLocation).where(StockLocation.hotel_id == HOTEL)
        )).all()
    }
    stock = Stock({
        (n.stock_location_id, n.product_id): n.quantity
        for n in (await session.scalars(select(StockLevel))).all()
    })

    ventes = planifier(jours, cartes, zone, bascule, maintenant)
    par_jour: dict[dt.date, list[Vente]] = defaultdict(list)
    for v in ventes:
        par_jour[v.jour].append(v)

    async def mouvement(cle: str, quand: dt.datetime, **champs) -> bool:
        id_ = _id("stock_movement", cle)
        if await session.get(StockMovement, id_) is not None:
            return False
        m = StockMovement(
            id=id_, hotel_id=HOTEL, moved_at=quand, moved_by=DEMO_ADMIN, created_at=quand, **champs
        )
        session.add(m)
        await session.flush()
        if m.status == StockMovementStatus.APPROVED:
            await record_entry_cost(session, m)
            await apply_movement(session, m)
            if m.type == StockMovementType.TRANSFER:
                stock.bouger(m.stock_location_id, m.product_id, -m.quantity)
                stock.bouger(m.counterpart_location_id, m.product_id, m.quantity)
            elif m.type == StockMovementType.IN:
                stock.bouger(m.stock_location_id, m.product_id, m.quantity)
            else:
                stock.bouger(m.stock_location_id, m.product_id, -m.quantity)
        compte["mouvements"] += 1
        return True

    # Ce que chaque semaine va consommer, lieu par lieu : ventes, cuisine, spa.
    semaine_de = {jour: i // 7 for i, jour in enumerate(jours)}
    besoins: dict[int, dict[tuple[str, str], float]] = defaultdict(lambda: defaultdict(float))
    usages: dict[dt.date, dict[tuple[str, str], float]] = defaultdict(lambda: defaultdict(float))
    ref_de = {p.id: p.reference for p in produits.values()}
    for v in ventes:
        s = semaine_de[v.jour]
        for article, q in v.lignes:
            if article.product_id is not None and article.product_id in ref_de:
                besoins[s][(v.point, ref_de[article.product_id])] += q * article.stock_quantity
            elif v.point in ("RESTO", "ROOM_SERVICE"):
                for ref, par_plat in CUISINE.items():
                    usages[v.jour][("CUISINE", ref)] += q * par_plat
        if v.point == "SPA":
            usages[v.jour][("SPA", SPA_HUILE[0])] += SPA_HUILE[1]
    for jour, u in usages.items():
        for cle, q in u.items():
            besoins[semaine_de[jour]][cle] += q

    for i, jour in enumerate(jours):
        semaine = semaine_de[jour]
        debut_de_semaine = i % 7 == 0
        derniere = semaine == semaine_de[jours[-1]]
        matin = _instant(jour, 7, 30, zone, bascule)
        # Les prix d'achat montent d'environ 6 % sur le mois.
        derive = -0.03 + 0.09 * i / max(len(jours) - 1, 1)

        # La consommation des chambres sort chaque debut de semaine : sa
        # presence dit que la semaine est deja traitee. Ses achats dependent
        # du stock du moment ; les recalculer a un second passage en
        # ajouterait d'autres.
        deja = await session.get(
            StockMovement, _id("stock_movement", f"menage:{jour}:{next(iter(MENAGE))}")
        )
        if debut_de_semaine and matin < maintenant and deja is None:
            # Le ravitaillement de la semaine, puis les achats qui le
            # permettent : l'economat garde deux fois son seuil.
            transferts: dict[str, int] = defaultdict(int)
            for (lieu_code, ref), besoin in sorted(besoins[semaine].items()):
                lieu, produit = lieux.get(lieu_code), produits.get(ref)
                if lieu is None or produit is None:
                    continue
                cible = (
                    produit.min_stock // 2
                    if derniere and (lieu_code, ref) in SOUS_LE_SEUIL
                    else produit.min_stock
                )
                quantite = math.ceil(besoin) + cible - stock[(lieu.id, produit.id)]
                if quantite > 0:
                    transferts[ref] += quantite
            for ref, besoin in MENAGE.items():
                transferts[ref] += besoin
            for ref, sortira in sorted(transferts.items()):
                produit = produits.get(ref)
                if produit is None:
                    continue
                manque = sortira + 2 * produit.min_stock - stock[(economat.id, produit.id)]
                if manque > 0:
                    lot = 6 * math.ceil(manque / 6)
                    await mouvement(
                        f"achat:{jour}:{ref}", matin - dt.timedelta(hours=1),
                        product_id=produit.id, stock_location_id=economat.id,
                        type=StockMovementType.IN, quantity=lot,
                        unit_cost=max(1, round(produit.purchase_price * (1 + derive))),
                        supplier_id=produit.default_supplier_id,
                        reason="Livraison fournisseur", status=StockMovementStatus.APPROVED,
                    )
            for (lieu_code, ref), besoin in sorted(besoins[semaine].items()):
                lieu, produit = lieux.get(lieu_code), produits.get(ref)
                if lieu is None or produit is None:
                    continue
                cible = (
                    produit.min_stock // 2
                    if derniere and (lieu_code, ref) in SOUS_LE_SEUIL
                    else produit.min_stock
                )
                quantite = math.ceil(besoin) + cible - stock[(lieu.id, produit.id)]
                if quantite > 0:
                    await mouvement(
                        f"ravitaillement:{jour}:{lieu_code}:{ref}", matin,
                        product_id=produit.id, stock_location_id=economat.id,
                        counterpart_location_id=lieu.id, type=StockMovementType.TRANSFER,
                        quantity=quantite, reason=f"Ravitaillement {lieu.label}",
                        status=StockMovementStatus.APPROVED,
                        decided_by=DEMO_ADMIN, decided_at=matin,
                    )
            for ref, quantite in MENAGE.items():
                produit = produits.get(ref)
                if produit is not None:
                    await mouvement(
                        f"menage:{jour}:{ref}", matin + dt.timedelta(hours=2),
                        product_id=produit.id, stock_location_id=economat.id,
                        type=StockMovementType.OUT, quantity=quantite,
                        unit_cost=unit_cost_of(produit), reason="Utilisé pour les chambres",
                        status=StockMovementStatus.APPROVED,
                    )

        # Ce que la cuisine et le spa ont utilise, sorti le soir.
        soir = _instant(jour, 22, 30, zone, bascule)
        if soir < maintenant:
            for (lieu_code, ref), q in sorted(usages[jour].items()):
                lieu, produit = lieux.get(lieu_code), produits.get(ref)
                quantite = math.ceil(q)
                if lieu is None or produit is None or quantite <= 0:
                    continue
                await mouvement(
                    f"usage:{jour}:{lieu_code}:{ref}", soir,
                    product_id=produit.id, stock_location_id=lieu.id,
                    type=StockMovementType.OUT, quantity=quantite,
                    unit_cost=unit_cost_of(produit),
                    reason="Utilisé en cuisine" if lieu_code == "CUISINE" else "Utilisé au spa",
                    status=StockMovementStatus.APPROVED,
                )

        await _jour(
            session, jour, aujourdhui, par_jour[jour], points, agents, stock, compte,
            zone, bascule,
        )
        await session.commit()

    # Aujourd'hui, le bar demande ses bieres : la demande attend le controleur.
    point, ref, quantite = DEMANDE_EN_ATTENTE
    if point in lieux and ref in produits:
        quand = maintenant - dt.timedelta(minutes=40)
        await mouvement(
            f"demande:{aujourdhui}:{point}:{ref}", quand,
            product_id=produits[ref].id, stock_location_id=economat.id,
            counterpart_location_id=lieux[point].id, type=StockMovementType.TRANSFER,
            quantity=quantite, reason=f"Ravitaillement {lieux[point].label}",
            status=StockMovementStatus.PENDING,
        )
    await _depenses(session, jours, compte)
    await session.commit()
    return dict(compte)


# Les depenses de la periode : (jour, rubrique, libelle, montant, moyen,
# fournisseur). Le jour est un rang dans les trente : 0 le plus ancien.
DEPENSES = [
    (2, ExpenseCategory.SALARIES, "Salaires du personnel", 1_850_000,
     PaymentMethod.TRANSFER, None),
    (3, ExpenseCategory.TELECOM, "Internet fibre et bouquet TV", 65_000,
     PaymentMethod.MOBILE_MONEY, "Camtel"),
    (5, ExpenseCategory.ELECTRICITY, "Facture d'électricité", 210_000,
     PaymentMethod.TRANSFER, "ENEO"),
    (8, ExpenseCategory.WATER, "Facture d'eau", 52_000,
     PaymentMethod.CASH, "Camwater"),
    (12, ExpenseCategory.REPAIRS, "Plomberie chambre 105", 38_000,
     PaymentMethod.CASH, None),
    (15, ExpenseCategory.MARKETING, "Affiches et publicité Facebook", 30_000,
     PaymentMethod.MOBILE_MONEY, None),
    (18, ExpenseCategory.TAXES, "Impôt libératoire du trimestre", 120_000,
     PaymentMethod.TRANSFER, "Impôts"),
    (20, ExpenseCategory.REPAIRS, "Recharge climatisation chambre 201", 25_000,
     PaymentMethod.CASH, None),
    (27, ExpenseCategory.BANK_FEES, "Frais de tenue de compte", 7_500,
     PaymentMethod.TRANSFER, "Banque"),
] + [
    # Le gasoil du groupe electrogene, chaque semaine.
    (j, ExpenseCategory.FUEL, "Gasoil du groupe électrogène", 45_000,
     PaymentMethod.CASH, "Station Tradex")
    for j in (1, 8, 15, 22, 29)
]


async def _depenses(
    session: AsyncSession, jours: list[dt.date], compte: dict[str, int]
) -> None:
    """Les depenses du mois, et un doublon annule : il ne doit pas compter."""
    for rang, rubrique, libelle, montant, moyen, fournisseur in DEPENSES:
        jour = jours[min(rang, len(jours) - 1)]
        id_ = _id("depense", f"{jour}:{libelle}")
        if await session.get(Expense, id_) is not None:
            continue
        session.add(Expense(
            id=id_, hotel_id=HOTEL, business_date=jour, category=rubrique,
            label=libelle, amount=montant, method=moyen, supplier=fournisseur,
            recorded_by=DEMO_ADMIN,
        ))
        compte["depenses"] += 1
    jour = jours[6]
    id_ = _id("depense", f"{jour}:doublon")
    if await session.get(Expense, id_) is None:
        session.add(Expense(
            id=id_, hotel_id=HOTEL, business_date=jour,
            category=ExpenseCategory.ELECTRICITY, label="Facture d'électricité",
            amount=210_000, method=PaymentMethod.TRANSFER, supplier="ENEO",
            recorded_by=DEMO_ADMIN, is_void=True,
            void_reason="Saisie en double",
        ))
        compte["depenses"] += 1


async def _jour(
    session: AsyncSession,
    jour: dt.date,
    aujourdhui: dt.date,
    ventes: list[Vente],
    points: dict[str, Outlet],
    agents: dict[str, uuid.UUID],
    stock: Stock,
    compte: dict[str, int],
    zone: ZoneInfo,
    bascule: int,
) -> None:
    """Les ventes d'une journee, leurs tiroirs et les versements a la reception."""
    passe = jour < aujourdhui
    rng = random.Random(f"caisse:{jour}")
    hier = aujourdhui - dt.timedelta(days=1)

    par_point: dict[str, list[Vente]] = defaultdict(list)
    for v in ventes:
        par_point[v.point].append(v)

    # La caisse centrale de la reception, ou entrent les versements du soir.
    centrale = await session.get(CashSession, _id("cash_session", f"CENTRALE:{jour}"))
    if centrale is None:
        ouverte = None
        if not passe:
            ouverte = await session.scalar(
                select(CashSession).where(
                    CashSession.user_id == DEMO_RECEPTION,
                    CashSession.outlet_id.is_(None),
                    CashSession.status == CashSessionStatus.OPEN,
                    CashSession.deleted_at.is_(None),
                )
            )
        if ouverte is not None:
            centrale = ouverte
        else:
            debut = min((v.servie for v in ventes), default=None)
            centrale = CashSession(
                id=_id("cash_session", f"CENTRALE:{jour}"), hotel_id=HOTEL,
                user_id=DEMO_RECEPTION, status=CashSessionStatus.OPEN,
                opened_at=min(
                    debut or _instant(jour, 7, 0, zone, bascule),
                    _instant(jour, 7, 0, zone, bascule),
                ) - dt.timedelta(minutes=30),
                opening_float=50000, expected_amount=0, variance=0,
            )
            centrale.created_at = centrale.opened_at
            session.add(centrale)
            await session.flush()

    for code, du_point in sorted(par_point.items()):
        point = points[code]
        profil = PROFILS[code]
        agent = agents[profil.agent]
        cle = _id("cash_session", f"{code}:{jour}")
        caisse = await session.get(CashSession, cle)
        if caisse is not None:
            # Deja charge ; un jour laisse ouvert hier se clot maintenant.
            if passe and caisse.status == CashSessionStatus.OPEN:
                await _clore(session, caisse, max(v.payee for v in du_point), rng, centrale, code, jour, hier)
            continue
        du_point.sort(key=lambda v: v.servie)
        if not passe:
            # Un tiroir deja ouvert par cet agent pour ce point de vente : on
            # y vend, il n'en faut pas un second.
            caisse = await session.scalar(
                select(CashSession).where(
                    CashSession.user_id == agent,
                    CashSession.outlet_id == point.id,
                    CashSession.status == CashSessionStatus.OPEN,
                    CashSession.deleted_at.is_(None),
                )
            )
        if caisse is None:
            caisse = CashSession(
                id=cle, hotel_id=HOTEL, user_id=agent, outlet_id=point.id,
                status=CashSessionStatus.OPEN,
                opened_at=du_point[0].servie - dt.timedelta(minutes=20),
                opening_float=profil.fond, expected_amount=0, variance=0,
            )
            caisse.created_at = caisse.opened_at
            session.add(caisse)
            await session.flush()

        impayee = (
            du_point[-1].rang
            if not passe and code in ARDOISES_A_PAYER and len(du_point) >= 2
            else None
        )
        for v in du_point:
            await _vendre(session, v, point, agent, caisse, stock, payee=v.rang != impayee)
            compte["ventes"] += 1
        if impayee is not None and code == "RESTO":
            folio = await session.get(Folio, _id("folio", f"{code}:{jour}:{impayee}"))
            if folio is not None:
                folio.tab_label = "Table 4"

        if passe:
            await _clore(
                session, caisse, du_point[-1].payee, rng, centrale, code, jour, hier
            )
        compte["tiroirs"] += 1

    if passe and centrale.status == CashSessionStatus.OPEN and centrale.id == _id(
        "cash_session", f"CENTRALE:{jour}"
    ):
        await session.flush()
        attendu = await _expected_cash(session, centrale)
        ecart = -1500 if rng.random() < 0.1 else 0
        centrale.status = CashSessionStatus.CLOSED
        centrale.closed_at = _instant(jour, 5, 50, zone, bascule)
        centrale.expected_amount = attendu
        centrale.counted_amount = attendu + ecart
        centrale.variance = ecart


async def _vendre(
    session: AsyncSession,
    v: Vente,
    point: Outlet,
    agent: uuid.UUID,
    caisse: CashSession,
    stock: Stock,
    *,
    payee: bool,
) -> None:
    """Une vente au comptoir, comme la tablette la remonte : l'ardoise, ses
    lignes (et ce qu'elles sortent du stock), puis le paiement du total."""
    folio = Folio(
        id=_id("folio", v.cle), hotel_id=HOTEL,
        number=await next_number(session, HOTEL, Scope.FOLIO),
        type=FolioType.WALK_IN, status=FolioStatus.OPEN, outlet_id=point.id,
        tab_number=v.rang, opened_at=v.servie,
        notes=f"Client divers n°{v.rang} - {point.label}",
    )
    folio.created_at = v.servie
    session.add(folio)
    await session.flush()
    categorie = categorie_pour(point.code)
    for j, (article, q) in enumerate(v.lignes):
        ligne = FolioItem(
            id=_id("folio_item", f"{v.cle}:{j}"), folio_id=folio.id, category=categorie,
            label=article.label, quantity=q, unit_price=article.price,
            amount=article.price * q, tax_amount=0, tax_rate=0, business_date=v.jour,
            source_table="outlets", source_id=point.id, posted_by=agent, posted_at=v.servie,
        )
        ligne.created_at = v.servie
        session.add(ligne)
        await session.flush()
        sortie = await deduct_for_sale(
            session, hotel_id=HOTEL, outlet_id=point.id, menu_item_id=article.id,
            quantity=q, folio_item_id=ligne.id, by=agent,
        )
        if sortie is not None:
            sortie.moved_at = v.servie
            sortie.created_at = v.servie
            # Le suivi des niveaux doit voir la vente : sans elle, le
            # ravitaillement de la semaine suivante est calcule trop juste.
            stock.bouger(sortie.stock_location_id, sortie.product_id, -sortie.quantity)
    await recompute_totals(session, folio)
    if not payee:
        return
    paiement = Payment(
        id=_id("payment", v.cle), hotel_id=HOTEL, folio_id=folio.id,
        cash_session_id=caisse.id, method=v.moyen, amount=folio.balance,
        received_by=agent, received_at=v.payee, business_date=v.jour,
    )
    paiement.created_at = v.payee
    session.add(paiement)
    await session.flush()
    await recompute_totals(session, folio)
    folio.status = FolioStatus.CLOSED
    folio.closed_at = v.payee


async def _clore(
    session: AsyncSession,
    caisse: CashSession,
    derniere_vente: dt.datetime,
    rng: random.Random,
    centrale: CashSession,
    code: str,
    jour: dt.date,
    hier: dt.date,
) -> None:
    """Le tiroir ferme apres la derniere vente, compte a l'aveugle (parfois
    un petit ecart), puis verse a la reception -- sauf, hier soir, le bar et
    la boite de nuit, dont la reception n'a pas encore confirme le versement."""
    await session.flush()
    attendu = await _expected_cash(session, caisse)
    ecart = _choisir(rng, [(0, 85.0), (-500, 6.0), (-1000, 4.0), (500, 3.0), (-2000, 2.0)])
    caisse.status = CashSessionStatus.CLOSED
    caisse.closed_at = derniere_vente + dt.timedelta(minutes=25)
    caisse.expected_amount = attendu
    caisse.counted_amount = attendu + ecart
    caisse.variance = ecart
    if jour == hier and code in VERSEMENTS_EN_ATTENTE:
        return
    perte = -1000 if rng.random() < 0.05 else 0
    caisse.received_amount = caisse.counted_amount + perte
    caisse.received_by = DEMO_RECEPTION
    caisse.received_at = caisse.closed_at + dt.timedelta(minutes=15)
    caisse.received_session_id = centrale.id


async def main() -> None:
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        compte = await charger(session)
    await engine.dispose()
    print(
        f"{compte.get('ventes', 0)} ventes, {compte.get('tiroirs', 0)} tiroirs, "
        f"{compte.get('mouvements', 0)} mouvements de stock, "
        f"{compte.get('depenses', 0)} depenses "
        "(0 au second passage le meme jour : deja charges)."
    )


if __name__ == "__main__":
    asyncio.run(main())
