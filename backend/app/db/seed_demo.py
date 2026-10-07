"""Donnees de test : une journee d'hotel en cours, creee par l'API.

Le jeu de demonstration de la tablette a ete retire le 30 septembre : ses
clients et ses sejours n'existaient que sur la tablette, et le premier depart
enregistre bloquait la file d'envoi (« reservation introuvable »). Celui-ci
vit sur le serveur : chaque tablette le recoit par la descente et peut le
modifier comme n'importe quel dossier.

Il passe par l'API, comme une tablette, et non par la base : numeros de
dossier, nuitees, ardoises, chambre sale au depart, chambre hors service sous
un ticket bloquant -- tout suit les memes regles que le travail reel. Et il
n'utilise que la bibliotheque standard : il tourne contre n'importe quel
serveur demarre, sans l'environnement du backend.

Ce qu'on obtient, autour de la journee hoteliere en cours :

- six clients installes, dont deux qui partent aujourd'hui ;
- deux departs deja faits (chambre a nettoyer, tache de menage ouverte) ;
- trois arrivees attendues, dont une avec arrhes ;
- deux reservations a venir ;
- une chambre hors service (climatisation) ;
- des consommations, des encaissements et une caisse ouverte.

Les identifiants sont fixes : le relancer ne cree rien en double, chaque
route rendant l'etat existant pour un id deja connu. Les dates partent de la
journee hoteliere du **premier** lancement ; pour une journee neuve, repartir
d'une base neuve (`app.db.seed`, puis ce script).

    python -m app.db.seed_demo
    python -m app.db.seed_demo --url http://192.168.1.20:8000/api/v1
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import urllib.error
import urllib.request

COMPTE = "ADMIN01"
MOT_DE_PASSE = "ChangeMe123!"

# Familles d'identifiants : `...-9000-` signe le jeu de test, l'octet suivant
# dit ce que c'est. On reconnait ainsi ces lignes d'un coup d'oeil en base.
CLIENT, DOSSIER, LIGNE, ARDOISE, CHARGE, PAIEMENT, MENAGE, TICKET = range(1, 9)


def ident(famille: int, rang: int) -> str:
    return f"01920000-0000-7000-9000-{famille:02x}{rang:010x}"


class Echec(Exception):
    pass


class Api:
    def __init__(self, base: str) -> None:
        self.base = base.rstrip("/")
        self.jeton: str | None = None

    def appel(self, methode: str, chemin: str, corps: dict | None = None, *, tolere=()):
        """Un appel JSON. Les codes de `tolere` sont signales, pas fatals."""
        donnees = None if corps is None else json.dumps(corps).encode()
        requete = urllib.request.Request(self.base + chemin, data=donnees, method=methode)
        requete.add_header("Content-Type", "application/json")
        if self.jeton:
            requete.add_header("Authorization", f"Bearer {self.jeton}")
        try:
            with urllib.request.urlopen(requete, timeout=30) as reponse:
                brut = reponse.read()
                return json.loads(brut) if brut else None
        except urllib.error.HTTPError as exc:
            detail = _detail(exc)
            if exc.code in tolere:
                print(f"    deja fait ou modifie depuis ({exc.code}) : {detail}")
                return None
            raise Echec(f"{methode} {chemin} -> {exc.code} : {detail}") from None
        except urllib.error.URLError as exc:
            raise Echec(
                f"Serveur injoignable sur {self.base} ({exc.reason}). Est-il demarre ?"
            ) from None


def _detail(exc: urllib.error.HTTPError) -> str:
    try:
        corps = json.loads(exc.read())
    except (ValueError, OSError):
        return exc.reason
    detail = corps.get("detail", corps) if isinstance(corps, dict) else corps
    return detail if isinstance(detail, str) else json.dumps(detail, ensure_ascii=False)


# Les clients : prenom, nom, nationalite, ville, telephone.
CLIENTS = [
    ("Awa", "Koné", "CI", "Abidjan", "+225 07 48 21 33 10"),
    ("Jean-Marc", "Mballa", "CM", "Douala", "+237 6 77 41 20 18"),
    ("Fatou", "Ndiaye", "SN", "Dakar", "+221 77 512 40 08"),
    ("Paul", "Essomba", "CM", "Yaoundé", "+237 6 99 02 14 77"),
    ("Aminata", "Traoré", "ML", "Bamako", "+223 76 41 22 90"),
    ("Koffi", "Yao", "CI", "Bouaké", "+225 05 66 10 72 41"),
    ("Mariam", "Ouédraogo", "BF", "Ouagadougou", "+226 70 21 45 63"),
    ("Didier", "Kouassi", "CI", "Yamoussoukro", "+225 01 02 87 45 19"),
    ("Nadia", "Bamba", "CI", "Abidjan", "+225 07 09 33 81 26"),
    ("Serge", "Atangana", "CM", "Yaoundé", "+237 6 70 88 13 52"),
    ("Clarisse", "N'Guessan", "CI", "San-Pédro", "+225 05 44 70 12 08"),
    ("Ibrahim", "Diallo", "GN", "Conakry", "+224 622 18 47 90"),
]

# Les sejours : client, chambre, arrivee et depart (en jours depuis
# aujourd'hui), etat voulu. `installe` : arrive, toujours la ; `parti` :
# arrive puis reparti aujourd'hui ; `attendu` : arrive aujourd'hui, pas
# encore la ; `a_venir` : plus tard.
SEJOURS = [
    (1, "102", -2, 2, "installe"),
    (2, "201", -1, 1, "installe"),
    (7, "309", 0, 3, "installe"),
    (8, "501", -3, 0, "installe"),
    (5, "402", -1, 0, "installe"),
    (9, "401", 0, 1, "installe"),
    (0, "204", -2, 0, "parti"),
    (11, "403", -1, 0, "parti"),
    (3, "302", 0, 2, "attendu"),
    (4, "103", 0, 3, "attendu"),
    (10, "502", 0, 1, "attendu"),
    (6, "510", 2, 5, "a_venir"),
    (11, "567", 7, 9, "a_venir"),
]

# Ce que les clients installes ont consomme : sejour, categorie, libelle,
# quantite, prix unitaire.
CONSOMMATIONS = [
    (0, "FNB", "Diner au restaurant", 2, 8_500),
    (0, "MINIBAR", "Minibar : biere locale", 2, 1_500),
    (2, "FNB", "Petit-dejeuner", 1, 6_000),
    (3, "LAUNDRY", "Blanchisserie", 1, 4_000),
    (3, "FNB", "Room service", 1, 12_500),
    (6, "MINIBAR", "Minibar : eau minerale", 3, 1_000),
    (7, "FNB", "Diner au restaurant", 1, 9_500),
]


def jour(aujourdhui: dt.date, decalage: int) -> str:
    return (aujourdhui + dt.timedelta(days=decalage)).isoformat()


def principal(base: str) -> None:
    api = Api(base)
    connexion = api.appel(
        "POST", "/auth/login", {"employee_code": COMPTE, "password": MOT_DE_PASSE}
    )
    api.jeton = connexion["access_token"]

    # La journee hoteliere du serveur, pas le calendrier de ce poste : avant
    # 6 h, c'est encore hier.
    aujourdhui = dt.date.fromisoformat(api.appel("GET", "/dashboard/summary")["business_date"])
    print(f"Journee hoteliere : {aujourdhui.isoformat()}")

    chambres = {c["number"]: c for c in api.appel("GET", "/rooms")}

    # Encaisser suppose une caisse ouverte : sans elle, les paiements ne
    # seraient rattaches a aucune session et l'ecart de fin de service
    # serait faux.
    api.appel("POST", "/cash-sessions", {"opening_float": 50_000, "notes": "Donnees de test"})
    print("Caisse ouverte (fond de 50 000 F).")

    for rang, (prenom, nom, pays, ville, telephone) in enumerate(CLIENTS):
        api.appel(
            "POST",
            "/guests",
            {
                "id": ident(CLIENT, rang),
                "first_name": prenom,
                "last_name": nom,
                "nationality": pays,
                "city": ville,
                "phone": telephone,
                "id_document_type": "ID_CARD",
                "id_document_number": f"C{pays}{48_210_000 + rang * 731}",
            },
        )
    print(f"{len(CLIENTS)} clients.")

    for rang, (client, numero, arrivee, depart, etat) in enumerate(SEJOURS):
        chambre = chambres.get(numero)
        if chambre is None:
            print(f"  chambre {numero} absente du plan : sejour saute.")
            continue
        dossier, ligne, ardoise = ident(DOSSIER, rang), ident(LIGNE, rang), ident(ARDOISE, rang)
        tarif = chambre["room_type"]["default_rate"]
        corps = {
            "id": dossier,
            "guest_id": ident(CLIENT, client),
            "source": "PHONE" if etat == "a_venir" else "DIRECT",
            "adults": 2 if rang % 3 == 0 else 1,
            "rooms": [
                {
                    "id": ligne,
                    "room_type_id": chambre["room_type"]["id"],
                    "arrival_date": jour(aujourdhui, arrivee),
                    "departure_date": jour(aujourdhui, depart),
                    "adults": 2 if rang % 3 == 0 else 1,
                }
            ],
        }
        # Une arrivee du jour a verse des arrhes par Mobile Money.
        if etat == "attendu" and numero == "502":
            corps |= {
                "deposit_amount": tarif // 2,
                "deposit_method": "MOBILE_MONEY",
                "deposit_reference": "OM-4821337",
            }
        api.appel("POST", "/reservations", corps)
        libelle = f"  {numero} : {CLIENTS[client][0]} {CLIENTS[client][1]}, {etat}"

        if etat in ("attendu", "a_venir"):
            print(libelle)
            continue

        reponse = api.appel(
            "POST",
            f"/reservations/{dossier}/rooms/{ligne}/check-in",
            {"room_id": chambre["id"], "folio_id": ardoise},
            tolere=(409,),
        )
        # Le serveur peut garder une ardoise qu'il connaissait deja : c'est
        # celle-la qu'il faut charger.
        if reponse and reponse.get("folio_id"):
            ardoise = reponse["folio_id"]

        # Les nuits deja passees, et celle de ce soir pour qui reste : c'est
        # ce que la tablette porte au check-in puis a chaque cloture.
        derniere = min(0, depart - 1)
        for nuit, decalage in enumerate(range(arrivee, derniere + 1)):
            date_nuit = aujourdhui + dt.timedelta(days=decalage)
            api.appel(
                "POST",
                f"/folios/{ardoise}/items",
                {
                    "id": ident(CHARGE, rang * 100 + nuit),
                    "category": "ROOM",
                    "label": f"Nuitee du {date_nuit.strftime('%d/%m')}",
                    "unit_price": tarif,
                    "night_date": date_nuit.isoformat(),
                },
            )
        for n, (sejour, categorie, intitule, quantite, prix) in enumerate(CONSOMMATIONS):
            if sejour == rang:
                api.appel(
                    "POST",
                    f"/folios/{ardoise}/items",
                    {
                        "id": ident(CHARGE, 9_000 + n),
                        "category": categorie,
                        "label": intitule,
                        "quantity": quantite,
                        "unit_price": prix,
                    },
                )

        if etat == "parti":
            # Le depart se fait note reglee, comme a la reception : on encaisse
            # le solde, on clot l'ardoise, puis la chambre part au menage.
            solde = api.appel("GET", f"/folios/{ardoise}")["balance"]
            if solde > 0:
                api.appel(
                    "POST",
                    f"/folios/{ardoise}/payments",
                    {"id": ident(PAIEMENT, rang), "method": "CASH", "amount": solde},
                )
            api.appel("POST", f"/folios/{ardoise}/close", tolere=(409,))
            api.appel("POST", f"/reservations/{dossier}/rooms/{ligne}/check-out")
            api.appel(
                "POST",
                "/housekeeping-tasks",
                {
                    "id": ident(MENAGE, rang),
                    "room_id": chambre["id"],
                    "type": "DEPARTURE",
                    "priority": "HIGH" if numero == "403" else "NORMAL",
                    "business_date": aujourdhui.isoformat(),
                },
            )
        elif rang in (0, 2):
            # Deux clients installes ont deja regle une partie de leur note.
            solde = api.appel("GET", f"/folios/{ardoise}")["balance"]
            acompte = min(solde, tarif)
            if acompte > 0:
                api.appel(
                    "POST",
                    f"/folios/{ardoise}/payments",
                    {
                        "id": ident(PAIEMENT, rang),
                        "method": "CARD" if rang == 0 else "MOBILE_MONEY",
                        "amount": acompte,
                        "reference": None if rang == 0 else "MOMO-77120",
                    },
                )
        print(libelle)

    if "203" in chambres:
        # Un ticket bloquant : c'est lui qui sort la chambre de la vente, pas
        # un drapeau pose a la main.
        api.appel(
            "POST",
            "/maintenance-tickets",
            {
                "id": ident(TICKET, 1),
                "room_id": chambres["203"]["id"],
                "category": "Climatisation",
                "title": "Climatisation en panne",
                "description": "Le client precedent signale un bruit puis un arret complet.",
                "priority": "HIGH",
                "blocks_room": True,
            },
        )
        print("  203 : hors service (climatisation).")

    resume = api.appel("GET", "/dashboard/summary")
    occupation = resume["occupancy"]
    print(
        "Fait. Arrivees du jour : {a}, departs : {d}, chiffre du jour : {ca} F.".format(
            a=resume["arrivals_today"], d=resume["departures_today"], ca=resume["today_revenue_total"]
        )
    )
    print(f"Occupation : {json.dumps(occupation, ensure_ascii=False)}")
    print("Sur la tablette : bouton Synchroniser du plan des chambres pour les recevoir.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--url",
        default="http://localhost:8000/api/v1",
        help="Adresse de l'API (par defaut : http://localhost:8000/api/v1)",
    )
    try:
        principal(parser.parse_args().url)
    except Echec as exc:
        sys.exit(f"Arret : {exc}")


if __name__ == "__main__":
    main()
