"""Pieces jointes : le fichier binaire, a cote de la ligne qui le decrit.

La file d'envoi de la tablette ne transporte que du JSON. Une photo de piece
d'identite remonte donc par sa propre route, en `multipart/form-data`, et la
ligne `attachments` nait avec elle : description et fichier arrivent ensemble,
ou pas du tout.

`PUT` et non `POST` : la tablette choisit l'identifiant, et une reprise du
recto renvoie le **meme** id avec une nouvelle photo. Un renvoi apres une
reponse perdue reecrit le meme fichier -- rien n'est jamais en double.
"""

from __future__ import annotations

import datetime as dt
import os
import uuid
from dataclasses import dataclass
from pathlib import Path

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Response,
    UploadFile,
    status,
)
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from app.api.deps import get_current_user, permission_codes
from app.core.config import settings
from app.db.session import get_session
from app.models import Attachment, Guest, User
from app.models.enums import UploadState
from app.schemas.attachments import AttachmentOut

router = APIRouter(prefix="/attachments", tags=["pieces jointes"])

_MIME_ACCEPTES = {"image/jpeg", "image/png"}


@dataclass(frozen=True)
class _Cible:
    """Ce a quoi une piece jointe peut s'accrocher, et qui peut y toucher."""

    model: type
    ecrire: str
    lire: str
    introuvable: str


# Les pieces d'identite seules pour l'instant. Une photo de panne s'ajoutera
# ici, avec ses propres droits : deposer une piece jointe, c'est modifier ce
# a quoi elle s'accroche.
_CIBLES = {
    "guests": _Cible(Guest, "guests.write", "guests.read", "Client introuvable."),
}


def _cible(entity_table: str) -> _Cible:
    cible = _CIBLES.get(entity_table)
    if cible is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"Pas de piece jointe sur '{entity_table}'.",
        )
    return cible


def _exiger(user: User, code: str) -> None:
    if code not in permission_codes(user):
        raise HTTPException(status.HTTP_403_FORBIDDEN, f"Permission manquante : {code}")


async def _verifier_entite(
    session: AsyncSession, cible: _Cible, entity_id: uuid.UUID, user: User
) -> None:
    """L'entite existe et appartient a l'hotel de l'appelant.

    `attachments` n'a pas de `hotel_id` : c'est l'entite qui porte le
    cloisonnement. Un client d'un autre hotel repond 404, comme partout.
    """
    entite = await session.get(cible.model, entity_id)
    if entite is None or entite.hotel_id != user.hotel_id or entite.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, cible.introuvable)


def _chemin(attachment_id: uuid.UUID) -> Path:
    # L'id seul, jamais un nom venu du client : il ne peut pas sortir du
    # dossier.
    return Path(settings.uploads_dir) / "attachments" / str(attachment_id)


def _ecrire(chemin: Path, octets: bytes) -> None:
    """Ecrit a cote puis renomme : une coupure en pleine ecriture ne laisse
    jamais une photo tronquee a la place de la bonne."""
    chemin.parent.mkdir(parents=True, exist_ok=True)
    provisoire = chemin.with_suffix(".part")
    provisoire.write_bytes(octets)
    os.replace(provisoire, chemin)


def _utc(instant: dt.datetime | None) -> dt.datetime | None:
    if instant is None or instant.tzinfo is not None:
        return instant
    return instant.replace(tzinfo=dt.timezone.utc)


async def _auteur(
    session: AsyncSession, captured_by: uuid.UUID | None, user: User
) -> uuid.UUID:
    """L'agent qui a pris la photo, s'il est connu dans cet hotel.

    Une tablette partagee prend la photo sous un agent et la remonte parfois
    sous un autre. Un id inconnu retombe sur l'appelant plutot que de faire
    echouer la cle etrangere -- et de laisser la photo sur la tablette.
    """
    if captured_by is None or captured_by == user.id:
        return user.id
    connu = await session.scalar(
        select(User.id).where(User.id == captured_by, User.hotel_id == user.hotel_id)
    )
    return connu or user.id


@router.put(
    "/{attachment_id}",
    response_model=AttachmentOut,
    status_code=status.HTTP_201_CREATED,
    responses={
        200: {"description": "Piece deja connue (meme id) : fichier remplace"},
        413: {"description": "Fichier trop lourd"},
    },
)
async def put_attachment(
    attachment_id: uuid.UUID,
    response: Response,
    entity_table: str = Form(max_length=64),
    entity_id: uuid.UUID = Form(),
    kind: str = Form(max_length=32),
    captured_at: dt.datetime | None = Form(None),
    captured_by: uuid.UUID | None = Form(None),
    file: UploadFile = File(),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> Attachment:
    """Recoit une piece jointe et son fichier, ou remplace le fichier.

    201 a la creation, 200 sur un renvoi ou une reprise. Une photo **plus
    ancienne** que celle deja tenue ne remplace rien et repond 200 : deux
    tablettes qui photographient le meme client, la derniere prise l'emporte,
    quel que soit l'ordre d'arrivee.
    """
    cible = _cible(entity_table)
    _exiger(user, cible.ecrire)
    await _verifier_entite(session, cible, entity_id, user)

    mime = (file.content_type or "").lower()
    if mime not in _MIME_ACCEPTES:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, f"Type de fichier refuse : {mime or '?'}."
        )
    octets = await file.read(settings.upload_max_bytes + 1)
    if not octets:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Fichier vide.")
    if len(octets) > settings.upload_max_bytes:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Fichier trop lourd.")

    captured_at = _utc(captured_at)
    piece = await session.get(Attachment, attachment_id)
    if piece is not None:
        if piece.entity_table != entity_table or piece.entity_id != entity_id:
            raise HTTPException(
                status.HTTP_409_CONFLICT, "Cette piece jointe appartient a une autre fiche."
            )
        response.status_code = status.HTTP_200_OK
        # Supprimee depuis, ou deja plus recente : la ressusciter ou la
        # remplacer par une photo anterieure serait faux, et la refuser
        # laisserait la tablette reessayer pour rien.
        if piece.deleted_at is not None:
            return piece
        tenue = _utc(piece.captured_at)
        if tenue is not None and captured_at is not None and captured_at < tenue:
            return piece

    # Le fichier d'abord : une ligne sans fichier annoncerait une photo
    # introuvable.
    await run_in_threadpool(_ecrire, _chemin(attachment_id), octets)

    champs = {
        "kind": kind,
        "file_url": f"{settings.api_prefix}/attachments/{attachment_id}/file",
        "mime_type": mime,
        "size_bytes": len(octets),
        "upload_state": UploadState.UPLOADED,
        "captured_at": captured_at,
        "captured_by": await _auteur(session, captured_by, user),
        "updated_by": user.id,
    }
    if piece is None:
        piece = Attachment(
            id=attachment_id,
            entity_table=entity_table,
            entity_id=entity_id,
            created_by=user.id,
            **champs,
        )
        session.add(piece)
    else:
        for nom, valeur in champs.items():
            setattr(piece, nom, valeur)
    await session.commit()
    await session.refresh(piece)
    return piece


@router.get(
    "/{attachment_id}/file",
    response_class=FileResponse,
    responses={200: {"content": {"image/jpeg": {}, "image/png": {}}}},
)
async def get_attachment_file(
    attachment_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> FileResponse:
    """Le fichier d'une piece jointe, avec les droits de lecture de sa fiche."""
    piece = await session.get(Attachment, attachment_id)
    if piece is None or piece.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Piece jointe introuvable.")
    cible = _cible(piece.entity_table)
    _exiger(user, cible.lire)
    await _verifier_entite(session, cible, piece.entity_id, user)

    chemin = _chemin(attachment_id)
    if not chemin.is_file():
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fichier absent du serveur.")
    return FileResponse(chemin, media_type=piece.mime_type or "application/octet-stream")
