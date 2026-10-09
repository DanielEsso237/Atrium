"""Le logo de l'hotel : envoye depuis l'administration, relu par chaque poste.

Ce qui compte : un PNG ou un JPEG seulement, reconnu a ses octets ; une
taille plafonnee ; une version qui ne change que si l'image change ; et le
nom de l'hotel modifiable sans toucher au reste du parametrage.
"""

from __future__ import annotations

import pytest

from app.api.v1.hotel import LOGO_MAX_OCTETS
from app.core.config import settings

from tests.test_client_de_passage import _agent

pytestmark = pytest.mark.db

PNG = b"\x89PNG\r\n\x1a\n" + b"logo" * 50
JPEG = b"\xff\xd8\xff\xe0" + b"logo" * 50


@pytest.fixture(autouse=True)
def dossier(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "uploads_dir", str(tmp_path))
    return tmp_path


@pytest.fixture
async def admin(client, hotel_a, login):
    return {"Authorization": f"Bearer {await login(client, 'ADMIN_A')}"}


async def _envoyer(client, auth, octets, mime="image/png"):
    return await client.put(
        "/api/v1/hotel/logo", files={"file": ("logo.png", octets, mime)}, headers=auth
    )


async def test_le_logo_arrive_puis_se_relit(client, admin, dossier):
    r = await _envoyer(client, admin, PNG)
    assert r.status_code == 200, r.text
    version = r.json()["logo_version"]
    assert version

    r = await client.get("/api/v1/hotel", headers=admin)
    assert r.json()["logo_version"] == version

    r = await client.get("/api/v1/hotel/logo", headers=admin)
    assert r.status_code == 200
    assert r.content == PNG
    assert r.headers["content-type"] == "image/png"


async def test_la_version_suit_l_image(client, admin, dossier):
    v1 = (await _envoyer(client, admin, PNG)).json()["logo_version"]
    assert (await _envoyer(client, admin, PNG)).json()["logo_version"] == v1
    v2 = (await _envoyer(client, admin, JPEG, "image/jpeg")).json()["logo_version"]
    assert v2 != v1
    # L'ancien fichier ne reste pas sur le disque.
    assert len(list(dossier.rglob("*.png"))) == 0
    assert len(list(dossier.rglob("*.jpg"))) == 1


async def test_un_faux_png_ou_un_logo_trop_lourd_est_refuse(client, admin):
    r = await _envoyer(client, admin, b"GIF89a" + b"x" * 40, "image/png")
    assert r.status_code == 422
    r = await _envoyer(client, admin, b"\x89PNG\r\n\x1a\n" + b"x" * LOGO_MAX_OCTETS)
    assert r.status_code == 413
    r = await client.get("/api/v1/hotel/logo", headers=admin)
    assert r.status_code == 404


async def test_retirer_le_logo(client, admin):
    await _envoyer(client, admin, PNG)
    r = await client.delete("/api/v1/hotel/logo", headers=admin)
    assert r.status_code == 204
    assert (await client.get("/api/v1/hotel", headers=admin)).json()["logo_version"] is None
    assert (await client.get("/api/v1/hotel/logo", headers=admin)).status_code == 404


async def test_sans_hotel_write_on_lit_mais_on_n_envoie_pas(
    client, session, hotel_a, admin, login
):
    hotel, _ = hotel_a
    await _envoyer(client, admin, PNG)
    await _agent(session, hotel, "RECEP_L", ["folio.read"])
    recep = {"Authorization": f"Bearer {await login(client, 'RECEP_L')}"}
    assert (await _envoyer(client, recep, JPEG, "image/jpeg")).status_code == 403
    assert (await client.delete("/api/v1/hotel/logo", headers=recep)).status_code == 403
    assert (await client.get("/api/v1/hotel/logo", headers=recep)).status_code == 200


async def test_renommer_l_hotel_garde_le_reste(client, admin):
    avant = (await client.get("/api/v1/hotel", headers=admin)).json()
    r = await client.patch(
        "/api/v1/hotel", json={"name": "Edge Hotel Plateau"}, headers=admin
    )
    assert r.status_code == 200, r.text
    apres = r.json()
    assert apres["name"] == "Edge Hotel Plateau"
    assert apres["timezone"] == avant["timezone"]
    assert apres["day_rollover_hour"] == avant["day_rollover_hour"]
