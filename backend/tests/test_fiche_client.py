"""Modifier un client ne touche qu'aux champs envoyes.

La tablette n'envoie que les champs de son ecran. Le `PATCH` ecrivait le
schema entier : chaque modification remettait a vide l'adresse, la date de
naissance et les notes. Un champ envoye a `null` s'efface, un champ absent
reste tel quel.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest

from app.models import Guest

pytestmark = pytest.mark.db


@pytest.fixture
async def auth_a(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def _client_complet(client, auth) -> str:
    resp = await client.post(
        "/api/v1/guests",
        json={
            "first_name": "Awa",
            "last_name": "Diallo",
            "phone": "690000000",
            "address": "Rue de la Joie",
            "birth_date": "1990-05-12",
            "notes": "Prefere le rez-de-chaussee",
        },
        headers=auth,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def test_les_champs_absents_restent_tels_quels(client, session, auth_a):
    guest_id = await _client_complet(client, auth_a)

    resp = await client.patch(
        f"/api/v1/guests/{guest_id}",
        json={"first_name": "Awa", "last_name": "Diallo", "nationality": "Camerounaise"},
        headers=auth_a,
    )

    assert resp.status_code == 200, resp.text
    session.expire_all()
    guest = await session.get(Guest, uuid.UUID(guest_id))
    assert guest.nationality == "Camerounaise"
    assert guest.address == "Rue de la Joie"
    assert guest.birth_date == dt.date(1990, 5, 12)
    assert guest.notes == "Prefere le rez-de-chaussee"
    assert guest.phone == "690000000"


async def test_un_champ_envoye_vide_s_efface(client, session, auth_a):
    guest_id = await _client_complet(client, auth_a)

    resp = await client.patch(
        f"/api/v1/guests/{guest_id}",
        json={"first_name": "Awa", "last_name": "Diallo", "phone": None},
        headers=auth_a,
    )

    assert resp.status_code == 200, resp.text
    session.expire_all()
    guest = await session.get(Guest, uuid.UUID(guest_id))
    assert guest.phone is None
    assert guest.address == "Rue de la Joie"


async def test_le_seuil_n_est_pas_efface_par_un_null(client, session, auth_a):
    guest_id = await _client_complet(client, auth_a)
    guest = await session.get(Guest, uuid.UUID(guest_id))
    guest.credit_limit = 100_000
    await session.commit()

    resp = await client.patch(
        f"/api/v1/guests/{guest_id}",
        json={"first_name": "Awa", "last_name": "Diallo", "credit_limit": None},
        headers=auth_a,
    )

    assert resp.status_code == 200, resp.text
    session.expire_all()
    assert (await session.get(Guest, uuid.UUID(guest_id))).credit_limit == 100_000


async def test_un_client_sans_telephone_ni_piece_se_cree_toujours(client, auth_a):
    # La regle des champs obligatoires est une regle de tablette : le serveur
    # ne refuse pas une creation ancienne qui attend encore dans une file.
    resp = await client.post(
        "/api/v1/guests", json={"first_name": "Amadou", "last_name": "Kone"}, headers=auth_a
    )
    assert resp.status_code == 201, resp.text
