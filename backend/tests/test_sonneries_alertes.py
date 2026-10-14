"""Les sonneries des alertes se choisissent depuis l'administration.

Meme regle que les niveaux : une sonnerie inconnue est refusee (la tablette
n'a pas le fichier, elle sonnerait le defaut sans le dire), un code
d'evenement inconnu est accepte (une tablette plus recente en connait
d'autres).
"""

from __future__ import annotations

import pytest

pytestmark = pytest.mark.db

URL = "/api/v1/settings/notification-sounds"


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def test_sans_reglage_la_lecture_rend_un_dictionnaire_vide(client, auth_a):
    resp = await client.get(URL, headers=auth_a)

    assert resp.status_code == 200, resp.text
    assert resp.json() == {"sounds": {}}


async def test_les_sonneries_ecrites_se_relisent_et_se_remplacent(client, auth_a):
    await client.put(URL, json={"sounds": {"LOW_STOCK": "WOOD"}}, headers=auth_a)
    sonneries = {"ROOM_TO_CLEAN": "BUBBLES", "FUTURE_EVENT": "RISING"}

    resp = await client.put(URL, json={"sounds": sonneries}, headers=auth_a)

    assert resp.status_code == 200, resp.text
    assert (await client.get(URL, headers=auth_a)).json() == {"sounds": sonneries}


@pytest.mark.parametrize(
    "corps",
    [
        {"sounds": {"LOW_STOCK": "TRUMPET"}},
        {"sounds": {"low_stock": "WOOD"}},
        {"sounds": {"LOW_STOCK": None}},
        {"levels": {}},
    ],
)
async def test_une_sonnerie_mal_formee_est_refusee(client, auth_a, corps):
    resp = await client.put(URL, json=corps, headers=auth_a)

    assert resp.status_code == 422, resp.text
