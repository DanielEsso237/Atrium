"""Routes parametrage de l'etablissement (paragraphe 6.5 -- ecran d'admin)."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, Response, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from app.api.deps import get_current_user, require_permission
from app.core.config import settings
from app.db.session import get_session
from app.models import Hotel, User
from app.schemas.hotel import HotelOut, HotelUpdate

router = APIRouter(prefix="/hotel", tags=["etablissement"])


@router.get("", response_model=HotelOut)
async def get_hotel(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> Hotel:
    """Lecture ouverte a tout utilisateur connecte : l'heure de bascule du

    jour hotelier (`day_rollover_hour`) sert de reference a tous les postes,
    pas seulement a l'administration.
    """
    hotel = await session.get(Hotel, user.hotel_id)
    if hotel is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Etablissement introuvable.")
    return hotel


@router.patch("", response_model=HotelOut)
async def update_hotel(
    payload: HotelUpdate,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("hotel.write")),
) -> Hotel:
    hotel = await session.get(Hotel, user.hotel_id)
    if hotel is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Etablissement introuvable.")
    # Les seuls champs envoyes : une tablette qui corrige le nom ne doit pas
    # remettre le fuseau ou l'heure de bascule a leur valeur par defaut.
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(hotel, field, value)
    await session.commit()
    await session.refresh(hotel)
    return hotel


# --- Le logo -----------------------------------------------------------------

# Un logo de facture, pas une photo : 512 Ko suffisent largement a une image
# nette en tete de page, et restent legers a faire descendre sur chaque poste.
LOGO_MAX_OCTETS = 512 * 1024

# Le type se reconnait aux premiers octets, pas a ce que le client annonce :
# un fichier renomme en .png n'en devient pas un.
_SIGNATURES = (
    (b"\x89PNG\r\n\x1a\n", "png", "image/png"),
    (b"\xff\xd8\xff", "jpg", "image/jpeg"),
)


def _fichier_logo(relatif: str) -> Path:
    return Path(settings.uploads_dir) / relatif


def _ecrire(chemin: Path, octets: bytes) -> None:
    """Ecrit a cote puis renomme : une coupure ne laisse jamais un logo
    tronque a la place du bon."""
    chemin.parent.mkdir(parents=True, exist_ok=True)
    provisoire = chemin.with_suffix(".part")
    provisoire.write_bytes(octets)
    os.replace(provisoire, chemin)


def _effacer(relatif: str | None) -> None:
    if not relatif:
        return
    try:
        _fichier_logo(relatif).unlink(missing_ok=True)
    except OSError:
        # Un ancien fichier qui reste sur le disque ne gene personne.
        pass


async def _hotel_de(session: AsyncSession, user: User) -> Hotel:
    hotel = await session.get(Hotel, user.hotel_id)
    if hotel is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Etablissement introuvable.")
    return hotel


@router.put(
    "/logo",
    response_model=HotelOut,
    responses={
        413: {"description": "Logo trop lourd (512 Ko au plus)"},
        422: {"description": "Ni PNG ni JPEG, ou fichier vide"},
    },
)
async def put_logo(
    file: UploadFile = File(),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("hotel.write")),
) -> Hotel:
    """Remplace le logo de l'etablissement.

    Le nom du fichier est l'empreinte de son contenu : renvoyer la meme image
    ne change rien, et `logo_version` ne bouge que si l'image change.
    """
    hotel = await _hotel_de(session, user)
    octets = await file.read(LOGO_MAX_OCTETS + 1)
    if not octets:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Fichier vide.")
    if len(octets) > LOGO_MAX_OCTETS:
        raise HTTPException(
            status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            "Logo trop lourd : 512 Ko au plus.",
        )
    extension = next((ext for sig, ext, _ in _SIGNATURES if octets.startswith(sig)), None)
    if extension is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "Le logo doit etre une image PNG ou JPEG.",
        )

    version = hashlib.sha256(octets).hexdigest()[:16]
    relatif = f"logos/{hotel.id}/{version}.{extension}"
    await run_in_threadpool(_ecrire, _fichier_logo(relatif), octets)

    ancien = hotel.logo_path
    hotel.logo_path = relatif
    await session.commit()
    await session.refresh(hotel)
    if ancien != relatif:
        await run_in_threadpool(_effacer, ancien)
    return hotel


@router.get(
    "/logo",
    response_class=FileResponse,
    responses={200: {"content": {"image/png": {}, "image/jpeg": {}}}},
)
async def get_logo(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> FileResponse:
    """Le logo, pour tout agent connecte : chaque poste l'imprime."""
    hotel = await _hotel_de(session, user)
    if not hotel.logo_path:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Aucun logo.")
    chemin = _fichier_logo(hotel.logo_path)
    if not chemin.is_file():
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fichier du logo absent du serveur.")
    mime = next(
        (m for _, ext, m in _SIGNATURES if hotel.logo_path.endswith(f".{ext}")),
        "application/octet-stream",
    )
    return FileResponse(chemin, media_type=mime)


@router.delete("/logo", status_code=status.HTTP_204_NO_CONTENT)
async def delete_logo(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("hotel.write")),
) -> Response:
    """Retire le logo : les factures reprennent le nom de l'hotel en tete."""
    hotel = await _hotel_de(session, user)
    ancien = hotel.logo_path
    hotel.logo_path = None
    await session.commit()
    await run_in_threadpool(_effacer, ancien)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
