"""Jetons de rafraichissement : generation et hachage, sans base."""

from __future__ import annotations

from app.core.security import hash_refresh_token, new_refresh_token


def test_hachage_deterministe_et_different_de_la_valeur():
    plain, hashed = new_refresh_token()
    assert hashed == hash_refresh_token(plain)
    assert plain not in hashed
    assert len(hashed) == 64


def test_deux_jetons_ne_se_ressemblent_pas():
    assert new_refresh_token()[0] != new_refresh_token()[0]
