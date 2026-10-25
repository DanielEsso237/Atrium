"""Les droits semes doivent se tenir entre eux.

Une permission manquante ne casse rien au demarrage : elle casse le jour ou
un agent fait son travail. C'est arrive avec la reception, qui pouvait
enregistrer une arrivee mais pas porter la nuitee que cette arrivee cree --
403 a chaque remontee, et la file d'envoi de la tablette bloquee derriere.

Ces tests lisent le semis et verifient les implications entre permissions.
Purs : aucune base.
"""

from __future__ import annotations

import pytest

from app.db.seed import PERMISSIONS, ROLE_PERMISSIONS, ROLES

CODE_PAR_ID = {pid: code for pid, code, _, _ in PERMISSIONS}
LIBELLE_PAR_ID = {rid: label for rid, _, label in ROLES}


def droits(role_id) -> set[str]:
    return {
        CODE_PAR_ID[perm_id]
        for r_id, perm_id in ROLE_PERMISSIONS
        if r_id == role_id
    }


# Ce qu'une action declenche implicitement. A gauche la permission qui autorise
# l'action, a droite celle que l'action va exiger derriere, sans que l'agent
# l'ait demandee.
IMPLICATIONS = [
    # Le check-in ouvre l'ardoise et y porte la nuitee (postStayNights).
    ("reservation.manage", "folio.write"),
    # Le check-out ouvre une tache de menage sur la chambre liberee.
    #
    # Cette ligne manquait, et le defaut est passe une deuxieme fois : la
    # reception enregistrait un depart puis se faisait refuser la tache. Le
    # test existait pourtant deja -- il ne couvrait simplement pas ce couple.
    ("reservation.manage", "housekeeping.manage"),
    # L'arrivee propose de photographier la piece d'identite, qui remonte
    # par `PUT /attachments` sous le droit d'ecrire la fiche client.
    ("reservation.manage", "guests.write"),
    # Creer une reservation suppose de pouvoir designer un client.
    ("reservation.create", "guests.read"),
    # L'arrivee directe (`POST /stays/walk-in`) cree le dossier, la fiche du
    # client si elle manque, et porte le sejour sur l'ardoise, d'un seul
    # geste. Meme piege que `folio.write` au check-in.
    ("reservation.create", "folio.write"),
    ("reservation.create", "guests.write"),
    # On ne nettoie pas une chambre dont on ignore le numero.
    ("housekeeping.read", "rooms.read"),
    # Faire le menage (migration 0033). « Commencer » sur une chambre sale
    # sans tache l'ouvre d'abord, puis la demarre (`startRoom` sur la
    # tablette) : qui commence doit aussi pouvoir ouvrir. Et il travaille
    # depuis la liste du menage, qui se lit sous `housekeeping.read`.
    ("housekeeping.work", "housekeeping.manage"),
    ("housekeeping.work", "housekeeping.read"),
    ("housekeeping.work", "rooms.read"),
    # Signaler une panne, c'est ouvrir un ticket que la tablette garde ensuite
    # a l'ecran : sans la lecture, le ticket disparaitrait sous les yeux de
    # celui qui vient de l'ouvrir. Et on designe la chambre en panne.
    ("maintenance.report", "maintenance.read"),
    ("maintenance.report", "rooms.read"),
    # Encaisser suppose une caisse : le paiement est rattache a la session
    # ouverte de celui qui encaisse. Sans elle, l'argent existe et n'est
    # rattache a personne, donc le rapport de shift ne tombe jamais juste.
    ("folio.write", "cash.session"),
    # Autoriser un depassement de seuil, c'est accepter un solde : il faut
    # pouvoir le lire avant de le laisser filer.
    ("folio.override_limit", "folio.read"),
    # L'ecran d'administration, garde par users.write, cree et desactive les
    # points de vente, lit la liste des agents, et ecrit le plafond d'un
    # client par la route des fiches.
    ("users.write", "restaurant.write"),
    ("users.write", "users.read"),
    ("users.write", "guests.write"),
    # Une commande portee a une chambre ecrit sur son ardoise.
    ("order.create", "folio.charge"),
    # Le client de passage paie au comptoir : la vente y est encaissee, dans
    # la caisse ouverte de l'agent (POST /folios/walk-in).
    ("order.create", "cash.session"),
    # Valider un transfert, c'est accepter de vider un magasin : il faut en
    # voir le stock avant.
    ("stock.transfer.approve", "stock.read"),
    # Entrees, transferts et validations se font tous depuis l'ecran Stocks,
    # que le routeur de la tablette n'ouvre qu'a qui lit le stock.
    ("stock.manage", "stock.read"),
    ("stock.transfer.request", "stock.read"),
    # Recevoir le versement d'un point de vente, c'est faire entrer des
    # especes dans un tiroir : il faut une caisse ou les mettre.
    ("cash.central", "cash.session"),
    # Vendre a un comptoir suppose de lire les points de vente et leur carte.
    ("order.create", "restaurant.read"),
    # L'ecran des depenses les liste avant de proposer d'en saisir : qui les
    # saisit doit pouvoir les lire.
    ("expense.write", "accounting.read"),
    # La commande en chambre (F2.6). La reception choisit le sejour parmi les
    # ardoises ouvertes (`GET /chargeable-stays`, sous folio.charge) et
    # l'article sur la carte du point de vente ; elle suit ensuite sa
    # commande par la descente (`GET /room-orders`, sous order.read).
    ("room_order.create", "folio.charge"),
    ("room_order.create", "restaurant.read"),
    ("room_order.create", "order.read"),
    # Le point de vente qui livre porte les lignes sur l'ardoise du sejour,
    # dans son tiroir ouvert, et voit arriver les commandes par la descente.
    ("order.manage", "folio.charge"),
    ("order.manage", "cash.session"),
    ("order.manage", "order.read"),
    # L'ecran Inventaire montre le stock du magasin a compter.
    ("stock.inventory", "stock.read"),
    ("stock.rebalance", "stock.read"),
]


@pytest.mark.parametrize("action, consequence", IMPLICATIONS)
def test_qui_peut_agir_peut_en_assumer_la_consequence(action, consequence):
    for role_id in LIBELLE_PAR_ID:
        acquis = droits(role_id)
        if action not in acquis:
            continue
        assert consequence in acquis, (
            f"{LIBELLE_PAR_ID[role_id]} a '{action}' mais pas '{consequence}' : "
            f"l'action produira une ecriture que le serveur lui refusera."
        )


def test_seul_l_encadrement_autorise_un_depassement_de_seuil():
    """Le seuil ne sert a rien si ceux qu'il arrete peuvent le lever seuls."""
    for role_id, libelle in LIBELLE_PAR_ID.items():
        if libelle in ("Reception", "Caisse", "Points de vente"):
            assert "folio.override_limit" not in droits(role_id), libelle
    manager = next(r for r, lab in LIBELLE_PAR_ID.items() if lab.startswith("Manager"))
    assert "folio.override_limit" in droits(manager)


def test_la_reception_facture_mais_ne_remise_pas():
    """La separation reception / caisse se joue sur la remise, pas sur la charge."""
    reception = droits(next(r for r, lab in LIBELLE_PAR_ID.items() if lab == "Reception"))

    assert "folio.write" in reception
    assert "folio.discount" not in reception


def test_ecrire_suppose_lire():
    """Un droit d'ecriture sans droit de lecture donne un ecran vide et actif."""
    for role_id, libelle in LIBELLE_PAR_ID.items():
        acquis = droits(role_id)
        for code in acquis:
            module, _, verbe = code.partition(".")
            if verbe not in ("write", "create", "manage"):
                continue
            lecture = f"{module}.read"
            if lecture not in CODE_PAR_ID.values():
                continue
            assert lecture in acquis, (
                f"{libelle} peut '{code}' sans pouvoir '{lecture}'."
            )


def test_toute_permission_rattachee_existe():
    """Un identifiant errant passerait inapercu jusqu'a la mise en service."""
    connus = set(CODE_PAR_ID)
    for role_id, perm_id in ROLE_PERMISSIONS:
        assert perm_id in connus, f"permission inconnue rattachee a {role_id}"
        assert role_id in LIBELLE_PAR_ID, f"role inconnu : {role_id}"


def test_la_reception_tient_la_caisse_centrale_et_vend_a_son_comptoir():
    """Decision du 8 octobre : les points de vente lui versent leur recette."""
    reception = droits(next(r for r, lab in LIBELLE_PAR_ID.items() if lab == "Reception"))

    assert "cash.central" in reception
    assert {"order.read", "order.create", "folio.charge"} <= reception


def test_un_point_de_vente_ne_confirme_pas_son_propre_versement():
    """Celui qui verse ne peut pas etre celui qui dit avoir recu."""
    comptoir = droits(next(r for r, lab in LIBELLE_PAR_ID.items() if lab == "Points de vente"))

    assert "cash.central" not in comptoir


def _role(code: str) -> set[str]:
    return droits(next(rid for rid, c, _ in ROLES if c == code))


def test_les_trois_metiers_du_stock_ont_chacun_leur_geste():
    """L'econome tient l'economat, les points de vente demandent, le
    controleur et le comptable valident."""
    assert {"stock.manage", "stock.transfer.request"} <= _role("ECONOME")
    assert "stock.transfer.request" in _role("RESTAURANT")
    assert "stock.transfer.approve" in _role("CONTROLEUR")
    assert "stock.transfer.approve" in _role("COMPTABLE")


def test_seul_l_econome_tient_l_economat():
    """Un point de vente qui saisirait ses propres entrees se ravitaillerait
    sans que personne ne valide rien."""
    for _, code, _ in ROLES:
        if code not in ("ADMIN", "ECONOME"):
            assert "stock.manage" not in _role(code), code


def test_qui_demande_un_transfert_ne_le_valide_pas():
    """Aucun metier ne porte les deux droits : le second regard vient d'un
    autre. L'administrateur a tout par construction ; le serveur lui refuse
    quand meme de valider sa propre demande."""
    for _, code, _ in ROLES:
        if code == "ADMIN":
            continue
        acquis = _role(code)
        assert not {"stock.transfer.request", "stock.transfer.approve"} <= acquis, code


def test_le_comptoir_et_l_econome_ne_lisent_pas_les_marges():
    """La marge d'un point de vente donne sa recette, que le comptoir compte
    a l'aveugle ; et c'est sur ses achats qu'on juge l'econome. La direction,
    le controleur et le comptable la lisent."""
    for code in ("MANAGER", "CONTROLEUR", "COMPTABLE"):
        assert "accounting.read" in _role(code), code
    for _, code, _ in ROLES:
        if code not in ("ADMIN", "MANAGER", "CONTROLEUR", "COMPTABLE"):
            assert "accounting.read" not in _role(code), code


def test_l_econome_lit_la_valeur_de_son_stock():
    """`GET /accounting/stock-value` s'ouvre a `stock.manage` : seul
    l'econome le porte, avec l'administrateur."""
    assert "stock.manage" in _role("ECONOME")
    assert "accounting.read" not in _role("ECONOME")


def test_la_reception_ouvre_le_menage_mais_ne_le_fait_pas():
    """Le depart ouvre une tache : la reception porte `housekeeping.manage`.
    La terminer a la place de la femme de chambre declarerait propre une
    chambre ou personne n'est passe (migration 0033)."""
    assert "housekeeping.manage" in _role("RECEPTION")
    assert "housekeeping.work" not in _role("RECEPTION")
    assert "housekeeping.work" in _role("HOUSEKEEPING")
