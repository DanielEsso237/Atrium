"""La regle des arrhes s'ecrit depuis l'administration, au format fixe.

`services/deposit.py` lisait deja `reservation.deposit_rule`, mais rien ne
permettait de l'ecrire. Une regle mal formee serait lue, en silence, comme
« pas d'arrhes » : elle est refusee a l'ecriture.
"""

from __future__ import annotations

import pytest

from app.services.deposit import deposit_from_rule

pytestmark = pytest.mark.db

URL = "/api/v1/settings/deposit-rule"


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def test_sans_regle_la_lecture_rend_null(client, auth_a):
    resp = await client.get(URL, headers=auth_a)

    assert resp.status_code == 200, resp.text
    assert resp.json() == {"rule": None}


async def test_la_regle_ecrite_est_celle_que_le_serveur_applique(client, auth_a):
    resp = await client.put(URL, json={"mode": "PERCENT", "rate_bp": 3000}, headers=auth_a)

    assert resp.status_code == 200, resp.text
    regle = (await client.get(URL, headers=auth_a)).json()["rule"]
    assert regle == {"mode": "PERCENT", "rate_bp": 3000}
    assert deposit_from_rule(regle, 25_000) == 7_500


async def test_reecrire_remplace_sans_doubler(client, auth_a):
    await client.put(URL, json={"mode": "PERCENT", "rate_bp": 3000}, headers=auth_a)
    await client.put(URL, json={"mode": "FIXED", "amount": 20000}, headers=auth_a)

    assert (await client.get(URL, headers=auth_a)).json()["rule"] == {
        "mode": "FIXED",
        "amount": 20000,
    }


@pytest.mark.parametrize(
    "corps",
    [
        {"mode": "FIXED"},
        {"mode": "FIXED", "amount": 0},
        {"mode": "PERCENT", "rate_bp": 20000},
        {"mode": "PERCENT", "amount": 5000},
        {"mode": "FIXED", "amount": 5000, "rate_bp": 3000},
        {"mode": "AUTRE", "amount": 5000},
    ],
)
async def test_une_regle_mal_formee_est_refusee(client, auth_a, corps):
    resp = await client.put(URL, json=corps, headers=auth_a)

    assert resp.status_code == 422, resp.text


async def test_retirer_la_regle(client, auth_a):
    await client.put(URL, json={"mode": "FIXED", "amount": 20000}, headers=auth_a)

    resp = await client.delete(URL, headers=auth_a)

    assert resp.status_code == 204
    assert (await client.get(URL, headers=auth_a)).json() == {"rule": None}
