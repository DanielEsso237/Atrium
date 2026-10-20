"""Le motif de l'ecart d'inventaire (F1.3).

`PUT /inventories/{id}/lines/{product_id}` accepte `comment` : le motif de
l'ecart, 255 caracteres au plus. Seuls les champs envoyes changent -- un
renvoi du seul comptage n'efface pas le motif, `null` l'efface.
"""

from __future__ import annotations

import pytest

from app.core.ids import uuid7
from tests.test_inventaire import URL, _ouverture, auth_a, economat  # noqa: F401 -- fixtures partagees

pytestmark = pytest.mark.db


async def _ouvrir(client, auth, economat):
    magasin, produits = economat
    corps = _ouverture(magasin, produits)
    r = await client.post(URL, json=corps, headers=auth)
    assert r.status_code == 201, r.text
    return corps["id"], produits[0]


def _ligne(inventaire: dict, produit) -> dict:
    return next(l for l in inventaire["lines"] if l["product_id"] == str(produit.id))


async def _compter(client, auth, inv, produit, **corps):
    return await client.put(f"{URL}/{inv}/lines/{produit.id}", json=corps, headers=auth)


async def test_le_motif_se_stocke_et_se_renvoie(client, auth_a, economat):
    inv, biere = await _ouvrir(client, auth_a, economat)

    r = await _compter(client, auth_a, inv, biere, counted_qty=7, comment="Casse constatee")

    assert r.status_code == 200, r.text
    ligne = _ligne(r.json(), biere)
    assert ligne["comment"] == "Casse constatee"
    assert ligne["counted_qty"] == 7
    assert ligne["variance"] == -3
    # Et il redescend a la lecture.
    lu = (await client.get(f"{URL}/{inv}", headers=auth_a)).json()
    assert _ligne(lu, biere)["comment"] == "Casse constatee"


async def test_un_comptage_sans_motif_ne_l_efface_pas(client, auth_a, economat):
    inv, biere = await _ouvrir(client, auth_a, economat)
    await _compter(client, auth_a, inv, biere, counted_qty=7, comment="Casse constatee")

    r = await _compter(client, auth_a, inv, biere, counted_qty=6)

    assert r.status_code == 200, r.text
    ligne = _ligne(r.json(), biere)
    assert ligne["counted_qty"] == 6
    assert ligne["comment"] == "Casse constatee"


async def test_un_motif_seul_ne_touche_pas_au_comptage(client, auth_a, economat):
    inv, biere = await _ouvrir(client, auth_a, economat)
    await _compter(client, auth_a, inv, biere, counted_qty=7)

    r = await _compter(client, auth_a, inv, biere, comment="Vol presume")

    assert r.status_code == 200, r.text
    ligne = _ligne(r.json(), biere)
    assert ligne["counted_qty"] == 7
    assert ligne["variance"] == -3
    assert ligne["comment"] == "Vol presume"


async def test_null_efface_le_motif(client, auth_a, economat):
    inv, biere = await _ouvrir(client, auth_a, economat)
    await _compter(client, auth_a, inv, biere, counted_qty=7, comment="Casse constatee")

    r = await _compter(client, auth_a, inv, biere, comment=None)

    assert r.status_code == 200, r.text
    ligne = _ligne(r.json(), biere)
    assert ligne["comment"] is None
    assert ligne["counted_qty"] == 7


async def test_un_motif_de_blancs_vaut_un_motif_efface(client, auth_a, economat):
    inv, biere = await _ouvrir(client, auth_a, economat)
    await _compter(client, auth_a, inv, biere, counted_qty=7, comment="Casse")

    r = await _compter(client, auth_a, inv, biere, comment="   ")

    assert r.status_code == 200, r.text
    assert _ligne(r.json(), biere)["comment"] is None


async def test_un_motif_trop_long_est_refuse(client, auth_a, economat):
    inv, biere = await _ouvrir(client, auth_a, economat)

    limite = await _compter(client, auth_a, inv, biere, counted_qty=7, comment="x" * 255)
    trop = await _compter(client, auth_a, inv, biere, counted_qty=7, comment="x" * 256)

    assert limite.status_code == 200, limite.text
    assert trop.status_code == 422, trop.text
    # Le refus n'a rien ecrit.
    lu = (await client.get(f"{URL}/{inv}", headers=auth_a)).json()
    assert _ligne(lu, biere)["comment"] == "x" * 255


async def test_rejouer_le_meme_envoi_rend_le_meme_etat(client, auth_a, economat):
    inv, biere = await _ouvrir(client, auth_a, economat)
    corps = {"counted_qty": 7, "comment": "Casse constatee"}

    premier = await _compter(client, auth_a, inv, biere, **corps)
    renvoi = await _compter(client, auth_a, inv, biere, **corps)

    assert (premier.status_code, renvoi.status_code) == (200, 200)
    assert _ligne(renvoi.json(), biere) == _ligne(premier.json(), biere)


async def test_le_renvoi_passe_meme_apres_le_reequilibrage(client, auth_a, economat):
    """Un refus (409) bloquerait la file de la tablette sur un geste deja passe."""
    inv, biere = await _ouvrir(client, auth_a, economat)
    corps = {"counted_qty": 7, "comment": "Casse constatee"}
    await _compter(client, auth_a, inv, biere, **corps)
    r = await client.post(
        f"{URL}/{inv}/rebalance", json={"movement_ids": {str(biere.id): str(uuid7())}},
        headers=auth_a,
    )
    assert r.status_code == 200, r.text

    renvoi = await _compter(client, auth_a, inv, biere, **corps)
    nouveau = await _compter(client, auth_a, inv, biere, comment="Autre motif")

    assert renvoi.status_code == 200, renvoi.text
    assert nouveau.status_code == 409, nouveau.text