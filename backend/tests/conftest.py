"""Fixtures partagees.

Deux familles de tests cohabitent ici :

- les tests **purs**, qui n'ont besoin d'aucune base et tournent partout, tout
  le temps. C'est la ou doit vivre le maximum de regles metier.
- les tests marques `@pytest.mark.db`, qui ont besoin d'un vrai PostgreSQL.
  Ils sont ignores automatiquement quand `TEST_DATABASE_URL` est absent, pour
  qu'un `pytest` sur une machine sans base reste vert au lieu de produire
  quarante erreurs de connexion qu'on apprend vite a ignorer.

Lancer les tests avec base :

    set TEST_DATABASE_URL=postgresql+asyncpg://atrium:...@localhost:5432/atrium_test
    pytest

La base de test est **creee et detruite a chaque session** : ne jamais pointer
`TEST_DATABASE_URL` sur la base de developpement.
"""

from __future__ import annotations

import os

import pytest

# SECRET_KEY est obligatoire depuis app/core/config.py. On la pose avant tout
# import de `app.*`, sinon la simple importation d'un module de l'application
# leverait une erreur de validation pendant la collecte des tests.
os.environ.setdefault("SECRET_KEY", "cle-de-test-uniquement-pour-pytest")
os.environ.setdefault("ENV", "dev")

TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL")


def pytest_collection_modifyitems(config, items):
    """Ignore les tests marques `db` quand aucune base de test n'est fournie."""
    if TEST_DATABASE_URL:
        return
    saute = pytest.mark.skip(
        reason="TEST_DATABASE_URL absent : test necessitant PostgreSQL ignore."
    )
    for item in items:
        if "db" in item.keywords:
            item.add_marker(saute)


@pytest.fixture(scope="session")
def database_url() -> str:
    """URL de la base de test, ou saute le test si elle n'est pas configuree."""
    if not TEST_DATABASE_URL:
        pytest.skip("TEST_DATABASE_URL absent.")
    return TEST_DATABASE_URL


# ---------------------------------------------------------------------------
# A COMPLETER -- fixtures de base de donnees
#
# Le squelette ci-dessous attend la branche `fix/hotel-scoping` : c'est la que
# les fixtures `session`, `client`, et surtout **deux hotels avec un
# utilisateur chacun** prennent leur sens, puisqu'elles servent a prouver
# qu'un utilisateur de l'hotel A ne voit pas les donnees de l'hotel B.
#
# La forme attendue :
#
#   @pytest.fixture
#   async def session(database_url): ...      # AsyncSession sur une base neuve
#   @pytest.fixture
#   async def hotel_a(session): ...           # + un utilisateur et son jeton
#   @pytest.fixture
#   async def hotel_b(session): ...
#   @pytest.fixture
#   async def client(session): ...            # httpx.AsyncClient sur app
#
# Elles ne sont pas ecrites ici pour ne pas figer un choix (base recreee par
# session ou transaction annulee par test) avant d'avoir un PostgreSQL sous la
# main pour mesurer lequel est tenable.
# ---------------------------------------------------------------------------
