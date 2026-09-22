"""Point d'entree FastAPI."""

from __future__ import annotations

from fastapi import FastAPI

from app.api.v1 import router as api_v1_router
from app.core.config import settings

app = FastAPI(title=settings.app_name, debug=settings.debug)


@app.get("/healthz", tags=["systeme"])
async def healthz() -> dict[str, str]:
    """Sonde de sante : verifie que l'API repond, sans toucher la base."""
    return {"status": "ok", "env": settings.env}


app.include_router(api_v1_router, prefix=settings.api_prefix)
