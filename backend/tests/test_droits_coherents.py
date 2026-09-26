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
    # Creer une reservation suppose de pouvoir designer un client.
    ("reservation.create", "guests.read"),
    # On ne nettoie pas une chambre dont on ignore le numero.
    ("housekeeping.read", "rooms.read"),
    # Encaisser suppose une caisse : le paiement est rattache a la session
    # ouverte de celui qui encaisse. Sans elle, l'argent existe et n'est
    # rattache a personne, donc le rapport de shift ne tombe jamais juste.
    ("folio.write", "cash.session"),
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
