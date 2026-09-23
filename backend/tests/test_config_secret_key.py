"""Le serveur doit refuser de demarrer sans vraie cle de signature.

Une cle par defaut connue publiquement rend tous les jetons JWT forgeables
par quiconque a lu le depot. Ces tests verifient que l'oubli devient une
panne bruyante au demarrage plutot qu'une faille silencieuse.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.core.config import Settings


def settings(**kwargs) -> Settings:
    """Construit un Settings sans lire le .env de la machine qui teste."""
    return Settings(_env_file=None, **kwargs)


def test_sans_secret_key_la_configuration_est_refusee(monkeypatch):
    """Sans la variable d'environnement, `Settings()` ne peut pas se construire.

    `conftest.py` pose SECRET_KEY pour que l'import de `app.*` fonctionne
    pendant la collecte ; il faut donc la retirer explicitement ici, sinon on
    testerait la configuration de la machine et pas le code.
    """
    monkeypatch.delenv("SECRET_KEY", raising=False)
    with pytest.raises(ValidationError) as erreur:
        settings(env="prod")
    assert "secret_key" in str(erreur.value)


def test_en_dev_une_cle_d_exemple_reste_toleree():
    """Sinon plus personne ne peut lancer le serveur en local sans ceremonie."""
    assert settings(env="dev", secret_key="change-me").secret_key == "change-me"


@pytest.mark.parametrize("exemple", ["change-me", "CHANGE-ME", "changeme", "secret"])
def test_hors_dev_une_cle_d_exemple_est_refusee(exemple):
    with pytest.raises(ValidationError) as erreur:
        settings(env="prod", secret_key=exemple)
    assert "exemple" in str(erreur.value)


def test_hors_dev_une_cle_trop_courte_est_refusee():
    with pytest.raises(ValidationError) as erreur:
        settings(env="prod", secret_key="a1b2c3d4")
    assert "32" in str(erreur.value)


def test_hors_dev_une_vraie_cle_passe():
    vraie = "Kx7pQ2mN8vR4tY6uI0oP3aS5dF9gH1jK2lZ8xC4vB6nM"
    assert settings(env="prod", secret_key=vraie).secret_key == vraie
