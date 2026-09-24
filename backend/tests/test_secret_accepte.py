"""Mot de passe ou code PIN : ce qui ouvre une session, et ce qui ne l'ouvre pas.

Le PIN etait hache et stocke depuis le debut, mais la connexion ne verifiait
que le mot de passe. Le pave numerique de l'ecran de connexion ne fonctionnait
donc qu'en mode hors ligne, ou c'est la tablette qui tranche.

Tests purs : aucune base, donc ils tournent partout et a chaque fois.
"""

from __future__ import annotations

from app.core.security import hash_secret, secret_accepte

MOT_DE_PASSE = "ChangeMe123!"
PIN = "1234"


def test_le_mot_de_passe_ouvre():
    assert secret_accepte(MOT_DE_PASSE, hash_secret(MOT_DE_PASSE), hash_secret(PIN))


def test_le_pin_ouvre_aussi():
    """Le coeur du correctif : dix agents se relaient sur la meme tablette."""
    assert secret_accepte(PIN, hash_secret(MOT_DE_PASSE), hash_secret(PIN))


def test_un_secret_inconnu_n_ouvre_pas():
    assert not secret_accepte("0000", hash_secret(MOT_DE_PASSE), hash_secret(PIN))


def test_un_compte_sans_pin_reste_ferme_au_pin():
    """Cas par defaut de tout compte cree par l'administration.

    Sans cette garantie, un `pin_hash` nul pourrait passer pour « pas de
    verification a faire » -- et ouvrirait le compte a n'importe quoi.
    """
    assert not secret_accepte(PIN, hash_secret(MOT_DE_PASSE), None)
    assert secret_accepte(MOT_DE_PASSE, hash_secret(MOT_DE_PASSE), None)


def test_un_compte_sans_aucun_secret_reste_ferme():
    """Un compte a moitie cree ne doit pas etre un compte grand ouvert."""
    assert not secret_accepte(PIN, None, None)
    assert not secret_accepte("", None, None)


def test_le_mot_de_passe_ne_passe_pas_pour_le_pin_d_un_autre():
    """Les deux hachages sont distincts : aucun ne valide le secret de l'autre."""
    assert not secret_accepte(MOT_DE_PASSE, hash_secret(PIN), None)
