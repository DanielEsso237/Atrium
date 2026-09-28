"""Regle de calcul des arrhes, lue dans `settings`. Pure : aucune base."""

from __future__ import annotations

import pytest

from app.services.deposit import deposit_from_rule


@pytest.mark.parametrize(
    "rule, total, attendu",
    [
        ({"mode": "FIXED", "amount": 20_000}, 50_000, 20_000),
        ({"mode": "PERCENT", "rate_bp": 3000}, 50_000, 15_000),  # 30 %
        ({"mode": "PERCENT", "rate_bp": 3333}, 25_000, 8_332),  # arrondi vers le bas
        ({"mode": "FIXED", "amount": 90_000}, 50_000, 50_000),  # jamais plus que le sejour
        (None, 50_000, 0),  # pas de regle : pas d'arrhes
        ({"mode": "FIXED"}, 50_000, 0),
        ({"mode": "PERCENT", "rate_bp": "30"}, 50_000, 0),  # illisible : pas d'invention
        ({"mode": "AUTRE", "amount": 1}, 50_000, 0),
        ({"mode": "FIXED", "amount": -5}, 50_000, 0),
        ("n'importe quoi", 50_000, 0),
    ],
)
def test_montant_des_arrhes(rule, total, attendu):
    assert deposit_from_rule(rule, total) == attendu
