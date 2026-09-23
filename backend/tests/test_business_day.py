"""La journee hoteliere ne commence pas a minuit, et pas dans le fuseau du serveur."""

from __future__ import annotations

import datetime as dt

import pytest

from app.services.business_day import business_date_for

ABIDJAN = "Africa/Abidjan"  # UTC+0 toute l'annee
DOUALA = "Africa/Douala"  # UTC+1 toute l'annee
PARIS = "Europe/Paris"  # UTC+1 / UTC+2 selon la saison


def utc(annee, mois, jour, heure, minute=0) -> dt.datetime:
    return dt.datetime(annee, mois, jour, heure, minute, tzinfo=dt.timezone.utc)


def test_apres_la_bascule_la_date_est_celle_du_jour():
    """10 h du matin a Abidjan : journee hoteliere du jour meme."""
    assert business_date_for(utc(2026, 9, 23, 10), ABIDJAN, 6) == dt.date(2026, 9, 23)


def test_avant_la_bascule_la_nuit_appartient_a_la_veille():
    """Un encaissement a 2 h du matin fait partie du chiffre d'affaires de la veille."""
    assert business_date_for(utc(2026, 9, 23, 2), ABIDJAN, 6) == dt.date(2026, 9, 22)


def test_la_bascule_elle_meme_ouvre_le_nouveau_jour():
    """6 h 00 pile : la limite appartient au jour qui commence, pas a celui qui finit."""
    assert business_date_for(utc(2026, 9, 23, 6), ABIDJAN, 6) == dt.date(2026, 9, 23)
    assert business_date_for(utc(2026, 9, 23, 5, 59), ABIDJAN, 6) == dt.date(2026, 9, 22)


def test_la_date_metier_peut_differer_de_la_date_du_serveur():
    """Le bug d'origine : `dt.date.today()` renvoyait la date du serveur.

    A 0 h 30 UTC le 24, un serveur naif ecrit `business_date = 24`. Pour
    l'hotel, la nuit du 23 n'est pas finie.
    """
    instant = utc(2026, 9, 24, 0, 30)
    assert instant.date() == dt.date(2026, 9, 24)
    assert business_date_for(instant, ABIDJAN, 6) == dt.date(2026, 9, 23)
    assert business_date_for(instant, DOUALA, 6) == dt.date(2026, 9, 23)


def test_deux_hotels_de_fuseaux_differents_ne_sont_pas_le_meme_jour():
    """Au meme instant, deux etablissements peuvent etre sur deux journees."""
    instant = utc(2026, 9, 23, 5, 30)
    assert business_date_for(instant, ABIDJAN, 6) == dt.date(2026, 9, 22)
    assert business_date_for(instant, PARIS, 6) == dt.date(2026, 9, 23)


def test_une_bascule_a_minuit_redonne_le_comportement_naif():
    """`day_rollover_hour = 0` desactive la regle sans cas particulier dans le code."""
    assert business_date_for(utc(2026, 9, 23, 2), ABIDJAN, 0) == dt.date(2026, 9, 23)


def test_un_instant_naif_est_lu_comme_de_l_utc():
    """Toute l'API horodate en UTC ; un datetime sans fuseau ne doit pas deriver."""
    naif = dt.datetime(2026, 9, 23, 10)
    assert business_date_for(naif, ABIDJAN, 6) == business_date_for(
        utc(2026, 9, 23, 10), ABIDJAN, 6
    )


@pytest.mark.parametrize("zone_invalide", ["Mars/Olympus_Mons", "", "n'importe quoi"])
def test_un_fuseau_inconnu_retombe_sur_le_defaut_sans_lever(zone_invalide):
    """Une zone absente de la base IANA ne doit jamais bloquer un encaissement."""
    assert business_date_for(utc(2026, 9, 23, 10), zone_invalide, 6) == dt.date(
        2026, 9, 23
    )
