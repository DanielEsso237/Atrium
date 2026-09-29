"""Le montage des tests voit quand le schema de la base a derive des modeles.

Sans base : la comparaison est une fonction pure, et le garde-fou ne lit que
l'URL.
"""

from __future__ import annotations

import pytest

from tests.schema_de_test import ecarts_de_schema, verifier_base_de_test


def test_une_colonne_ajoutee_au_modele_est_vue():
    # Le cas du 29 septembre : `credit_limit` ajoutee au modele, absente de la
    # base de test creee avant.
    modele = {"guests": {"id", "last_name", "credit_limit"}}
    base = {"guests": {"id", "last_name"}}

    assert ecarts_de_schema(modele, base) == ["guests.credit_limit manque dans la base"]


def test_une_colonne_retiree_du_modele_est_vue():
    modele = {"guests": {"id"}}
    base = {"guests": {"id", "fax"}}

    assert ecarts_de_schema(modele, base) == ["guests.fax n'existe plus dans le modele"]


def test_un_schema_a_jour_ne_declenche_rien():
    modele = {"guests": {"id", "last_name"}, "rooms": {"id", "number"}}

    assert ecarts_de_schema(modele, dict(modele)) == []


def test_une_table_absente_est_laissee_a_create_all():
    # `create_all` sait creer une table ; ce n'est pas une derive.
    assert ecarts_de_schema({"user_outlets": {"user_id"}}, {}) == []


@pytest.mark.parametrize(
    "url",
    [
        "postgresql+asyncpg://atrium:x@localhost:5432/atrium",
        "postgresql+asyncpg://atrium:x@localhost:5432/atrium_test_copie",
        "postgresql+asyncpg://atrium:x@localhost:5432/",
    ],
)
def test_le_montage_refuse_une_base_qui_n_est_pas_de_test(url):
    with pytest.raises(RuntimeError, match="_test"):
        verifier_base_de_test(url)


def test_le_montage_accepte_la_base_de_test():
    verifier_base_de_test("postgresql+asyncpg://atrium:x@localhost:5432/atrium_test")
