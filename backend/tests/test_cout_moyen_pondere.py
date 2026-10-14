"""Le cout moyen pondere : la regle, sans base.

Tous les chiffres sont calcules a la main, en francs entiers.
"""

from __future__ import annotations

import pytest

from app.services.costing import margin_rate_bp, weighted_average_cost


def test_deux_livraisons_se_moyennent_selon_leurs_quantites():
    # 10 bieres a 500 + 10 a 600 = 11 000 pour 20 bieres.
    assert weighted_average_cost(10, 500, 10, 600) == 550
    # 20 a 550 (11 000) + 10 a 700 (7 000) = 18 000 pour 30.
    assert weighted_average_cost(20, 550, 10, 700) == 600
    # Une petite livraison chere pese peu : 90 a 500 + 10 a 1 000 = 55 000 pour 100.
    assert weighted_average_cost(90, 500, 10, 1_000) == 550


def test_le_cout_s_arrondit_au_franc_le_plus_proche():
    # 3 a 100 + 1 a 101 = 401 pour 4, soit 100,25.
    assert weighted_average_cost(3, 100, 1, 101) == 100
    # 1 a 100 + 1 a 101 = 201 pour 2, soit 100,5 : au franc superieur.
    assert weighted_average_cost(1, 100, 1, 101) == 101
    # 1 a 100 + 2 a 101 = 302 pour 3, soit 100,67.
    assert weighted_average_cost(1, 100, 2, 101) == 101


def test_une_entree_sans_prix_ne_change_pas_le_cout():
    """La compter a zero ferait croire a des bieres gratuites."""
    assert weighted_average_cost(10, 500, 10, 0) == 500


@pytest.mark.parametrize("stock", [0, -4])
def test_un_stock_vide_ou_negatif_ne_pese_rien(stock):
    """Ce qui manque n'a pas de cout a moyenner : l'entree fixe le cout."""
    assert weighted_average_cost(stock, 500, 10, 600) == 600


def test_la_premiere_entree_valorisee_fixe_le_cout():
    assert weighted_average_cost(10, 0, 5, 400) == 400


def test_le_taux_de_marge_est_en_points_de_base():
    # 950 de marge sur 1 500 = 63,33 %.
    assert margin_rate_bp(950, 1_500) == 6_333
    # Vendre a perte : -100 sur 400 = -25 %.
    assert margin_rate_bp(-100, 400) == -2_500
    assert margin_rate_bp(0, 0) is None
