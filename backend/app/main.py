"""Point d'entree FastAPI."""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1 import router as api_v1_router
from app.core.config import settings

app = FastAPI(title=settings.app_name, debug=settings.debug)

# L'authentification passe par un en-tete `Authorization`, jamais par un
# cookie : `allow_credentials` reste donc a False, ce qui autorise le joker
# `*` en developpement (un navigateur refuse la combinaison des deux).
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/healthz", tags=["systeme"])
async def healthz() -> dict[str, str]:
    """Sonde de sante : verifie que l'API repond, sans toucher la base."""
    return {"status": "ok", "env": settings.env}


app.include_router(api_v1_router, prefix=settings.api_prefix)
