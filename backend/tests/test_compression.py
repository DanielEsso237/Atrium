"""Les reponses volumineuses partent compressees.

La synchronisation d'une tablette relit des centaines de lignes a chaque
passage, souvent par ngrok ou la 4G : sans compression, c'est le debit qui
fixe sa duree.
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import app


def test_une_grosse_reponse_part_compressee():
    # Le schema OpenAPI : volumineux, et servi sans base de donnees.
    reponse = TestClient(app).get("/openapi.json", headers={"Accept-Encoding": "gzip"})
    assert reponse.status_code == 200
    assert reponse.headers["content-encoding"] == "gzip"


def test_sans_gzip_annonce_la_reponse_reste_en_clair():
    reponse = TestClient(app).get("/openapi.json", headers={"Accept-Encoding": "identity"})
    assert "content-encoding" not in reponse.headers


def test_une_petite_reponse_n_est_pas_compressee():
    reponse = TestClient(app).get("/healthz", headers={"Accept-Encoding": "gzip"})
    assert "content-encoding" not in reponse.headers
