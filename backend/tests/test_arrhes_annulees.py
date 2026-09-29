"""Les arrhes d'une reservation annulee sont soldees.

Avant, a l'annulation, le paiement restait rattache a la reservation pour
toujours : l'argent n'etait jamais reconnu, aucun document n'etait emis, et le
total des arrhes en attente grossissait sans que rien ne le vide.

Desormais l'annulation ouvre une ardoise d'indemnite au nom du client, y
porte une charge du montant des arrhes et y transfere le paiement : solde nul,
ardoise close, facturable par `POST /folios/{id}/invoice`. Une annulation
rejouee ne reconnait rien deux fois.
"""

from __future__ import annotations

import uuid

import pytest

from app.core.ids import uuid7
from tests.test_arrhes_en_caisse import (  # noqa: F401 -- fixtures partagees
    _expected,
    _open_cash,
    _payments,
    _reserve,
    auth_a,
    rooms_a,
)

pytestmark = pytest.mark.db

PENDING = "/api/v1/reservations/deposits/pending"


async def _pending(client, auth) -> tuple[int, int]:
    resp = await client.get(PENDING, headers=auth)
    assert resp.status_code == 200, resp.text
    return resp.json()["count"], resp.json()["total"]


async def _cancel(client, auth, body, **extra):
    return await client.post(
        f"/api/v1/reservations/{body['id']}/cancel",
        json={"reason": "Vol annule", **extra},
        headers=auth,
    )


async def test_annulation_apres_arrhes_plus_rien_n_est_rattache(
    client, session, auth_a, rooms_a
):
    await _open_cash(client, auth_a)
    body, _ = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=10_000, deposit_method="CASH"
    )
    folio_id = str(uuid7())
    resp = await _cancel(client, auth_a, body, folio_id=folio_id)
    assert resp.status_code == 200, resp.text

    assert await _payments(session, reservation_id=uuid.UUID(body["id"])) == []
    [payment] = await _payments(session)
    assert str(payment.folio_id) == folio_id

    folio = (await client.get(f"/api/v1/folios/{folio_id}", headers=auth_a)).json()
    assert folio["status"] == "CLOSED"
    assert (folio["charges_total"], folio["payments_total"], folio["balance"]) == (
        10_000,
        10_000,
        0,
    )
    assert folio["guest_id"] == body["guest_id"]
    [item] = folio["items"]
    assert item["category"] == "MISC"
    assert "Indemnite d'annulation" in item["label"]
    # L'argent ne bouge pas de la caisse : il change seulement de statut.
    assert await _expected(client, auth_a) == 20_000


async def test_le_total_en_attente_baisse_d_autant(client, auth_a, rooms_a):
    await _open_cash(client, auth_a)
    kept, _ = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=10_000, deposit_method="CASH"
    )
    cancelled, _ = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=5_000, deposit_method="MOBILE_MONEY"
    )
    assert await _pending(client, auth_a) == (2, 15_000)

    assert (await _cancel(client, auth_a, cancelled)).status_code == 200
    assert await _pending(client, auth_a) == (1, 10_000)
    assert kept  # l'autre dossier garde ses arrhes en attente


async def test_rejeu_de_l_annulation_pas_de_double_reconnaissance(
    client, session, auth_a, rooms_a
):
    await _open_cash(client, auth_a)
    body, _ = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=10_000, deposit_method="CASH"
    )
    folio_id = str(uuid7())
    assert (await _cancel(client, auth_a, body, folio_id=folio_id)).status_code == 200
    again = await _cancel(client, auth_a, body, folio_id=str(uuid7()))
    assert again.status_code == 200

    folios = (
        await client.get(f"/api/v1/folios?guest_id={body['guest_id']}", headers=auth_a)
    ).json()
    assert [f["id"] for f in folios] == [folio_id]
    assert len(await _payments(session)) == 1
    assert await _pending(client, auth_a) == (0, 0)


async def test_l_indemnite_se_facture(client, auth_a, rooms_a):
    await _open_cash(client, auth_a)
    body, _ = await _reserve(
        client, auth_a, rooms_a[0], deposit_amount=10_000, deposit_method="CASH"
    )
    folio_id = str(uuid7())
    await _cancel(client, auth_a, body, folio_id=folio_id)

    resp = await client.post(f"/api/v1/folios/{folio_id}/invoice", headers=auth_a)
    assert resp.status_code == 201, resp.text
    assert resp.json()["total"] == 10_000


async def test_annulation_sans_arrhes_n_ouvre_aucune_ardoise(client, auth_a, rooms_a):
    body, _ = await _reserve(client, auth_a, rooms_a[0])
    assert (await _cancel(client, auth_a, body)).status_code == 200
    folios = (
        await client.get(f"/api/v1/folios?guest_id={body['guest_id']}", headers=auth_a)
    ).json()
    assert folios == []
