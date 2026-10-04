"""Les photos de piece d'identite remontent par leur propre route.

La file de la tablette ne porte que du JSON : le fichier arrive en multipart
sur `PUT /attachments/{id}`. Ce qui compte : un renvoi ne cree rien en double,
une reprise remplace la photo, une photo plus ancienne n'ecrase pas la plus
recente, et la piece d'un client reste dans son hotel.
"""

from __future__ import annotations

import uuid

import pytest

from app.core.config import settings
from app.core.ids import uuid7
from app.models import Attachment

pytestmark = pytest.mark.db

JPEG = b"\xff\xd8\xff\xe0" + b"recto" * 20


@pytest.fixture(autouse=True)
def dossier(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "uploads_dir", str(tmp_path))
    return tmp_path


async def _auth(client, login, code):
    return {"Authorization": f"Bearer {await login(client, code)}"}


async def _client(client, auth) -> str:
    resp = await client.post(
        "/api/v1/guests", json={"first_name": "Awa", "last_name": "Diallo"}, headers=auth
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def _deposer(client, auth, piece_id, guest_id, octets=JPEG, **champs):
    return await client.put(
        f"/api/v1/attachments/{piece_id}",
        data={"entity_table": "guests", "entity_id": guest_id, "kind": "ID_FRONT", **champs},
        files={"file": ("recto.jpg", octets, "image/jpeg")},
        headers=auth,
    )


async def test_la_photo_arrive_puis_se_relit(client, session, hotel_a, login):
    auth = await _auth(client, login, "ADMIN_A")
    guest_id = await _client(client, auth)
    piece_id = str(uuid7())

    resp = await _deposer(client, auth, piece_id, guest_id)

    assert resp.status_code == 201, resp.text
    corps = resp.json()
    assert corps["upload_state"] == "UPLOADED"
    assert corps["size_bytes"] == len(JPEG)
    assert corps["file_url"] == f"/api/v1/attachments/{piece_id}/file"

    fichier = await client.get(corps["file_url"], headers=auth)
    assert fichier.status_code == 200
    assert fichier.content == JPEG
    assert fichier.headers["content-type"] == "image/jpeg"


async def test_un_renvoi_remplace_sans_doublon(client, session, hotel_a, login):
    auth = await _auth(client, login, "ADMIN_A")
    guest_id = await _client(client, auth)
    piece_id = str(uuid7())

    assert (await _deposer(client, auth, piece_id, guest_id)).status_code == 201
    reprise = await _deposer(
        client, auth, piece_id, guest_id, octets=b"\xff\xd8reprise",
        captured_at="2026-10-04T10:00:00Z",
    )

    assert reprise.status_code == 200, reprise.text
    session.expire_all()
    pieces = (await session.execute(Attachment.__table__.select())).all()
    assert len(pieces) == 1
    fichier = await client.get(f"/api/v1/attachments/{piece_id}/file", headers=auth)
    assert fichier.content == b"\xff\xd8reprise"


async def test_une_photo_plus_ancienne_n_ecrase_pas(client, session, hotel_a, login):
    auth = await _auth(client, login, "ADMIN_A")
    guest_id = await _client(client, auth)
    piece_id = str(uuid7())

    await _deposer(client, auth, piece_id, guest_id, captured_at="2026-10-04T10:00:00Z")
    tardive = await _deposer(
        client, auth, piece_id, guest_id, octets=b"\xff\xd8ancienne",
        captured_at="2026-10-04T09:00:00Z",
    )

    # Acceptee sans rien changer : la refuser ferait reessayer la tablette.
    assert tardive.status_code == 200
    fichier = await client.get(f"/api/v1/attachments/{piece_id}/file", headers=auth)
    assert fichier.content == JPEG


async def test_la_piece_reste_dans_son_hotel(client, session, hotel_a, hotel_b, login):
    auth_a = await _auth(client, login, "ADMIN_A")
    auth_b = await _auth(client, login, "ADMIN_B")
    guest_a = await _client(client, auth_a)
    piece_id = str(uuid7())
    await _deposer(client, auth_a, piece_id, guest_a)

    assert (await _deposer(client, auth_b, str(uuid7()), guest_a)).status_code == 404
    lecture = await client.get(f"/api/v1/attachments/{piece_id}/file", headers=auth_b)
    assert lecture.status_code == 404


async def test_ce_qui_n_est_pas_une_photo_est_refuse(client, session, hotel_a, login):
    auth = await _auth(client, login, "ADMIN_A")
    guest_id = await _client(client, auth)

    pdf = await client.put(
        f"/api/v1/attachments/{uuid7()}",
        data={"entity_table": "guests", "entity_id": guest_id, "kind": "ID_FRONT"},
        files={"file": ("x.pdf", b"%PDF", "application/pdf")},
        headers=auth,
    )
    assert pdf.status_code == 422

    ailleurs = await client.put(
        f"/api/v1/attachments/{uuid7()}",
        data={"entity_table": "rooms", "entity_id": str(uuid.uuid4()), "kind": "PHOTO"},
        files={"file": ("x.jpg", JPEG, "image/jpeg")},
        headers=auth,
    )
    assert ailleurs.status_code == 422


async def test_un_fichier_trop_lourd_est_refuse(client, session, hotel_a, login, monkeypatch):
    monkeypatch.setattr(settings, "upload_max_bytes", 10)
    auth = await _auth(client, login, "ADMIN_A")
    guest_id = await _client(client, auth)

    resp = await _deposer(client, auth, str(uuid7()), guest_id)

    assert resp.status_code == 413
