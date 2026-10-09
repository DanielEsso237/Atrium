"""Les niveaux des alertes se fixent depuis l'administration.

Le serveur ne fait pas sonner les tablettes : il garde les niveaux pour
qu'elles sonnent toutes de la meme facon. Une valeur inconnue est refusee
(la tablette la lirait comme le defaut, sans le dire), un code d'evenement
inconnu est accepte (une tablette plus recente en connait d'autres).
"""

from __future__ import annotations

import pytest

pytestmark = pytest.mark.db

URL = "/api/v1/settings/notification-levels"


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def test_sans_reglage_la_lecture_rend_un_dictionnaire_vide(client, auth_a):
    resp = await client.get(URL, headers=auth_a)

    assert resp.status_code == 200, resp.text
    assert resp.json() == {"levels": {}}


async def test_les_niveaux_ecrits_se_relisent(client, auth_a):
    niveaux = {"ARRIVAL_EXPECTED": "SOUND", "LOW_STOCK": "SILENT"}

    resp = await client.put(URL, json={"levels": niveaux}, headers=auth_a)

    assert resp.status_code == 200, resp.text
    assert (await client.get(URL, headers=auth_a)).json() == {"levels": niveaux}


async def test_reecrire_remplace_sans_doubler(client, auth_a):
    await client.put(URL, json={"levels": {"LOW_STOCK": "SILENT"}}, headers=auth_a)
    await client.put(
        URL, json={"levels": {"SYNC_BLOCKED": "SOUND_VIBRATION"}}, headers=auth_a
    )

    assert (await client.get(URL, headers=auth_a)).json() == {
        "levels": {"SYNC_BLOCKED": "SOUND_VIBRATION"}
    }


async def test_un_evenement_inconnu_est_garde(client, auth_a):
    resp = await client.put(
        URL, json={"levels": {"FUTURE_EVENT": "SOUND"}}, headers=auth_a
    )

    assert resp.status_code == 200, resp.text


@pytest.mark.parametrize(
    "corps",
    [
        {"levels": {"LOW_STOCK": "LOUD"}},
        {"levels": {"low_stock": "SOUND"}},
        {"levels": {"LOW_STOCK": None}},
        {"niveaux": {}},
    ],
)
async def test_un_niveau_mal_forme_est_refuse(client, auth_a, corps):
    resp = await client.put(URL, json=corps, headers=auth_a)

    assert resp.status_code == 422, resp.text
