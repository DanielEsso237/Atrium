"""Les depenses de l'hotel hors stock : saisies sur la tablette, souvent hors
ligne, et remontees par la file d'envoi.

Ce qui compte ici, c'est ce qu'un renvoi fait : la meme creation, la meme
correction, la meme annulation, rejouees, ne doivent rien changer ni rien
refuser -- un refus bloquerait la file de la tablette.
"""

from __future__ import annotations

import datetime as dt

import pytest

from app.core.ids import uuid7
from tests.test_client_de_passage import _agent

pytestmark = pytest.mark.db

URL = "/api/v1/expenses"


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


def _depense(**champs):
    return {
        "id": str(uuid7()),
        "business_date": (dt.date.today() - dt.timedelta(days=2)).isoformat(),
        "category": "ELECTRICITY",
        "label": "Facture ENEO septembre",
        "amount": 185000,
        "method": "TRANSFER",
        **champs,
    }


async def test_une_depense_renvoyee_n_est_creee_qu_une_fois(client, auth_a):
    corps = _depense()

    premier = await client.post(URL, json=corps, headers=auth_a)
    renvoi = await client.post(URL, json=corps, headers=auth_a)

    assert premier.status_code == 201, premier.text
    assert renvoi.status_code == 200, renvoi.text
    liste = (await client.get(URL, headers=auth_a)).json()
    assert [d["id"] for d in liste] == [corps["id"]]
    assert liste[0]["amount"] == 185000


async def test_corriger_puis_renvoyer_la_correction(client, auth_a):
    corps = _depense()
    await client.post(URL, json=corps, headers=auth_a)
    correction = {k: v for k, v in corps.items() if k != "id"} | {"amount": 192500}

    r = await client.patch(f"{URL}/{corps['id']}", json=correction, headers=auth_a)
    renvoi = await client.patch(f"{URL}/{corps['id']}", json=correction, headers=auth_a)

    assert r.status_code == 200, r.text
    assert renvoi.status_code == 200, renvoi.text
    assert renvoi.json()["amount"] == 192500


async def test_annulee_elle_reste_et_ne_se_corrige_plus(client, auth_a):
    corps = _depense()
    await client.post(URL, json=corps, headers=auth_a)

    r = await client.post(
        f"{URL}/{corps['id']}/void", json={"reason": "Saisie en double"}, headers=auth_a
    )
    renvoi = await client.post(
        f"{URL}/{corps['id']}/void", json={"reason": "Autre motif"}, headers=auth_a
    )
    correction = {k: v for k, v in corps.items() if k != "id"} | {"amount": 1000}
    refus = await client.patch(f"{URL}/{corps['id']}", json=correction, headers=auth_a)

    assert r.status_code == 200 and r.json()["is_void"] is True
    # Le premier motif fait foi.
    assert renvoi.json()["void_reason"] == "Saisie en double"
    assert refus.status_code == 409
    # Toujours listee : une autre tablette doit apprendre l'annulation.
    assert (await client.get(URL, headers=auth_a)).json()[0]["is_void"] is True


@pytest.mark.parametrize(
    "champs",
    [
        {"amount": 0},
        {"amount": 1_000_000_001},
        {"label": ""},
        {"category": "CASINO"},
        {"business_date": (dt.date.today() + dt.timedelta(days=3)).isoformat()},
    ],
)
async def test_une_depense_mal_formee_est_refusee(client, auth_a, champs):
    r = await client.post(URL, json=_depense(**champs), headers=auth_a)

    assert r.status_code == 422, r.text


async def test_la_periode_filtre_les_journees(client, auth_a):
    vieille = _depense(business_date="2026-01-15")
    recente = _depense()
    for corps in (vieille, recente):
        await client.post(URL, json=corps, headers=auth_a)

    r = await client.get(URL, params={"since": "2026-02-01"}, headers=auth_a)

    assert [d["id"] for d in r.json()] == [recente["id"]]


async def test_le_comptoir_ne_voit_ni_ne_saisit_les_depenses(
    client, session, hotel_a, login
):
    hotel, _ = hotel_a
    await _agent(session, hotel, "DEP_C", ["order.create", "cash.session"])
    headers = {"Authorization": f"Bearer {await login(client, 'DEP_C')}"}

    assert (await client.get(URL, headers=headers)).status_code == 403
    assert (await client.post(URL, json=_depense(), headers=headers)).status_code == 403


async def test_le_controleur_lit_sans_saisir(client, session, hotel_a, login):
    hotel, _ = hotel_a
    await _agent(session, hotel, "DEP_L", ["accounting.read"])
    headers = {"Authorization": f"Bearer {await login(client, 'DEP_L')}"}

    assert (await client.get(URL, headers=headers)).status_code == 200
    assert (await client.post(URL, json=_depense(), headers=headers)).status_code == 403
