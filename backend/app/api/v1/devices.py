"""Les tablettes de l'hotel, et ce qui bloque leur file d'envoi.

Un refus du serveur bloque la file d'une tablette, avec tout ce qui attend
derriere. Le blocage ne se voyait que sur la tablette elle-meme : la
reception pouvait travailler une demi-journee sans que rien ne remonte, et
personne d'autre ne le savait.

La tablette annonce ici son blocage, **hors de sa file** -- elle est
justement bloquee --, puis le dit leve. Les rapports redescendent vers qui
porte `sync.monitor` (administration, direction), sur tous les postes.

Annoncer et lever sont ouverts a tout agent connecte : le rapport part avec
la session de qui tient la tablette, souvent un autre que l'auteur de
l'ecriture refusee. Il ne dit rien qu'un droit protege a qui l'envoie.

Un responsable abandonne l'ecriture d'ici (`/decide`, `sync.monitor`) ; la
tablette bloquee lit la decision a son passage suivant
(`/sync-blocks/decisions`), la reverifie et l'applique, puis leve le blocage
comme d'habitude (`REMOVED`). Le serveur ne touche a aucune donnee metier :
l'ecriture n'existe que sur la tablette.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user, require_permission
from app.db.base import utcnow
from app.db.session import get_session
from app.models import AuditLog, Device, RefreshToken, SyncBlock, User
from app.schemas.devices import (
    DeviceIn,
    DeviceOut,
    DeviceRenameIn,
    DeviceRevokeIn,
    SyncBlockDecideIn,
    SyncBlockIn,
    SyncBlockOut,
    SyncBlockResolveIn,
    SyncDecisionOut,
)

router = APIRouter(tags=["tablettes"])

# Un blocage leve reste visible une semaine : assez pour qu'on voie qu'il a
# eu lieu, pas assez pour encombrer l'ecran.
FENETRE_LEVES = dt.timedelta(days=7)

# Le contenu d'un changement de PIN ou d'un code oublie porte des secrets ;
# ils n'ont rien a faire dans un rapport que la direction lit.
_MOTS_SECRETS = {"secret", "password", "pin", "token", "hash"}


def sans_secrets(valeur: Any) -> Any:
    """[valeur] sans les cles qui designent un secret, a toute profondeur.

    Par mot de la cle (`approver_pin`, `new_password`), pas par sous-chaine :
    `shipping` n'est pas un PIN.
    """
    if isinstance(valeur, dict):
        return {
            cle: sans_secrets(v)
            for cle, v in valeur.items()
            if not (_MOTS_SECRETS & set(str(cle).lower().split("_")))
        }
    if isinstance(valeur, list):
        return [sans_secrets(v) for v in valeur]
    return valeur


def refuser_si_revoquee(tablette: Device | None) -> None:
    """Le refus dedie d'une tablette revoquee : 410, que la tablette lit
    comme l'ordre d'effacer sa base et sa cle. Jamais un 401 ou un 403, qui
    se lisent comme un code faux ou un droit manquant."""
    if tablette is not None and tablette.revoked_at is not None:
        raise HTTPException(status.HTTP_410_GONE, "Cette tablette a ete revoquee.")


async def _presenter(session: AsyncSession, user: User, payload: DeviceIn) -> Device:
    tablette = await session.get(Device, payload.id)
    if tablette is not None and tablette.hotel_id != user.hotel_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Tablette inconnue.")
    refuser_si_revoquee(tablette)
    maintenant = utcnow()
    if tablette is None:
        tablette = Device(
            id=payload.id,
            hotel_id=user.hotel_id,
            device_uid=str(payload.id),
            name=payload.name,
            created_by=user.id,
        )
        session.add(tablette)
    tablette.app_version = payload.app_version
    tablette.os_version = payload.os_version
    tablette.last_seen_at = maintenant
    tablette.updated_by = user.id
    # Sans relation declaree, rien n'ordonne les insertions : la tablette doit
    # exister avant le rapport qui la designe.
    await session.flush()
    return tablette


@router.put("/devices/me", response_model=DeviceOut)
async def present_device(
    payload: DeviceIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> Device:
    """La tablette se presente a chaque connexion en ligne."""
    tablette = await _presenter(session, user, payload)
    await session.commit()
    await session.refresh(tablette)
    return tablette


async def _tablette_de_l_hotel(session: AsyncSession, user: User, device_id) -> Device:
    tablette = await session.get(Device, device_id)
    if tablette is None or tablette.hotel_id != user.hotel_id or tablette.deleted_at:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Tablette inconnue.")
    return tablette


@router.patch("/devices/{device_id}", response_model=DeviceOut)
async def rename_device(
    device_id: uuid.UUID,
    payload: DeviceRenameIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("sync.monitor")),
) -> Device:
    """Donner un nom parlant (« Reception 1 ») a la place de « Tablette 3F2A ».
    La tablette ne l'ecrase jamais : elle ne donne son nom par defaut qu'a sa
    premiere presentation."""
    tablette = await _tablette_de_l_hotel(session, user, device_id)
    tablette.name = payload.name.strip()
    tablette.updated_by = user.id
    await session.commit()
    await session.refresh(tablette)
    return tablette


@router.post("/devices/{device_id}/revoke", response_model=DeviceOut)
async def revoke_device(
    device_id: uuid.UUID,
    payload: DeviceRevokeIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("sync.monitor")),
) -> Device:
    """Retirer une tablette perdue ou volee.

    Ses sessions tombent tout de suite (jetons de rafraichissement retires) ;
    a son prochain contact -- connexion, presentation --, elle recoit un 410
    et efface sa base et sa cle. Ce qu'elle n'avait pas remonte est perdu :
    c'est le prix d'une base qui ne doit plus etre lue. La premiere
    revocation fait foi.
    """
    tablette = await _tablette_de_l_hotel(session, user, device_id)
    if tablette.revoked_at is not None:
        return tablette
    maintenant = utcnow()
    tablette.revoked_at = maintenant
    tablette.revoked_by = user.id
    tablette.revocation_reason = payload.reason
    tablette.is_active = False
    tablette.updated_by = user.id
    await session.execute(delete(RefreshToken).where(RefreshToken.device_id == tablette.id))
    session.add(
        AuditLog(
            user_id=user.id,
            device_id=tablette.id,
            entity_table="devices",
            entity_id=tablette.id,
            action="DEVICE_REVOKE",
            after={"name": tablette.name, "reason": payload.reason},
            occurred_at=maintenant,
        )
    )
    await session.commit()
    await session.refresh(tablette)
    return tablette


@router.get("/devices", response_model=list[DeviceOut])
async def list_devices(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("sync.monitor")),
) -> list[Device]:
    result = await session.scalars(
        select(Device)
        .where(Device.hotel_id == user.hotel_id, Device.deleted_at.is_(None))
        .order_by(Device.name)
    )
    return list(result.all())


@router.post(
    "/sync-blocks",
    response_model=SyncBlockOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Rapport deja recu (meme id), mis a jour"}},
)
async def report_sync_block(
    payload: SyncBlockIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> SyncBlock:
    rapport = await session.get(SyncBlock, payload.id)
    if rapport is not None and rapport.hotel_id != user.hotel_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifiant inconnu.")
    tablette = await _presenter(session, user, payload.device)
    if rapport is not None and rapport.device_id != tablette.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifiant inconnu.")
    maintenant = utcnow()

    if rapport is not None:
        response.status_code = status.HTTP_200_OK
        # Un rapport renvoye apres la levee arrive en retard : la levee fait foi.
        if rapport.status == "OPEN":
            rapport.pending_behind = payload.pending_behind
            rapport.http_status = payload.http_status
            rapport.reason = payload.reason
            rapport.abandonable = payload.abandonable
            rapport.abandon_note = payload.abandon_note
            if not payload.abandonable and rapport.decision is not None:
                # La tablette a reverifie et refuse : une saisie suivante en
                # depend desormais. La decision tombe, la note dit pourquoi.
                rapport.decision = None
                rapport.decision_reason = None
                rapport.decided_by = None
                rapport.decided_at = None
            rapport.reported_at = maintenant
            rapport.reported_by = user.id
            rapport.updated_by = user.id
        await session.commit()
        await session.refresh(rapport)
        return rapport

    auteur = None
    if payload.author_id is not None:
        # Un auteur d'un autre hotel ne se nomme pas ici.
        candidat = await session.get(User, payload.author_id)
        if candidat is not None and candidat.hotel_id == user.hotel_id:
            auteur = candidat.id
    rapport = SyncBlock(
        id=payload.id,
        hotel_id=user.hotel_id,
        device_id=tablette.id,
        author_id=auteur,
        reported_by=user.id,
        entity_table=payload.entity_table,
        entity_id=payload.entity_id,
        operation=payload.operation,
        payload=sans_secrets(payload.payload),
        http_status=payload.http_status,
        reason=payload.reason,
        written_at=payload.written_at,
        blocked_at=payload.blocked_at,
        reported_at=maintenant,
        pending_behind=payload.pending_behind,
        abandonable=payload.abandonable,
        abandon_note=payload.abandon_note,
        status="OPEN",
        created_by=user.id,
    )
    session.add(rapport)
    await session.commit()
    await session.refresh(rapport)
    return rapport


@router.post("/sync-blocks/{block_id}/resolve", response_model=SyncBlockOut)
async def resolve_sync_block(
    block_id: uuid.UUID,
    payload: SyncBlockResolveIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> SyncBlock:
    rapport = await session.get(SyncBlock, block_id)
    if rapport is None or rapport.hotel_id != user.hotel_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Rapport inconnu.")
    if rapport.status == "OPEN":
        rapport.status = "RESOLVED"
        rapport.resolution = payload.resolution
        rapport.resolved_at = payload.resolved_at
        rapport.updated_by = user.id
        await session.commit()
        await session.refresh(rapport)
    # Deja leve : le renvoi ne change rien, la premiere levee fait foi.
    return rapport


@router.post("/sync-blocks/{block_id}/decide", response_model=SyncBlockOut)
async def decide_sync_block(
    block_id: uuid.UUID,
    payload: SyncBlockDecideIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("sync.monitor")),
) -> SyncBlock:
    """Un responsable abandonne l'ecriture qui bloque une tablette."""
    rapport = await session.get(SyncBlock, block_id)
    if rapport is None or rapport.hotel_id != user.hotel_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Rapport inconnu.")
    if rapport.decision is not None:
        # Deja decide : la premiere decision fait foi, le renvoi ne change rien.
        return rapport
    if rapport.status != "OPEN":
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Ce blocage est deja leve : il n'y a rien a abandonner."
        )
    if not rapport.abandonable:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            rapport.abandon_note or "La tablette dit que cette saisie ne s'abandonne pas.",
        )
    maintenant = utcnow()
    rapport.decision = payload.decision
    rapport.decision_reason = payload.reason
    rapport.decided_by = user.id
    rapport.decided_at = maintenant
    rapport.updated_by = user.id
    # Une saisie perdue a dessein : la trace dit qui, pourquoi et quoi.
    session.add(
        AuditLog(
            user_id=user.id,
            device_id=rapport.device_id,
            entity_table=rapport.entity_table,
            entity_id=rapport.entity_id,
            action="SYNC_ABANDON",
            after={
                "sync_block_id": str(rapport.id),
                "reason": payload.reason,
                "author_id": str(rapport.author_id) if rapport.author_id else None,
                "operation": rapport.operation,
                "payload": rapport.payload,
            },
            occurred_at=maintenant,
        )
    )
    await session.commit()
    await session.refresh(rapport)
    return rapport


@router.get("/sync-blocks/decisions", response_model=list[SyncDecisionOut])
async def list_sync_decisions(
    device_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> list[SyncBlock]:
    """Les decisions qui attendent la tablette [device_id].

    Ouvert a tout agent connecte, comme l'annonce : la decision part avec la
    session de qui tient la tablette bloquee, souvent pas un responsable.
    """
    result = await session.scalars(
        select(SyncBlock)
        .where(
            SyncBlock.hotel_id == user.hotel_id,
            SyncBlock.device_id == device_id,
            SyncBlock.status == "OPEN",
            SyncBlock.decision.is_not(None),
            SyncBlock.deleted_at.is_(None),
        )
        .order_by(SyncBlock.blocked_at)
    )
    return list(result.all())


@router.get("/sync-blocks", response_model=list[SyncBlockOut])
async def list_sync_blocks(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("sync.monitor")),
) -> list[SyncBlock]:
    """Les blocages en cours, et ceux leves depuis une semaine."""
    depuis = utcnow() - FENETRE_LEVES
    result = await session.scalars(
        select(SyncBlock)
        .where(
            SyncBlock.hotel_id == user.hotel_id,
            SyncBlock.deleted_at.is_(None),
            or_(SyncBlock.status == "OPEN", SyncBlock.resolved_at >= depuis),
        )
        .order_by(SyncBlock.blocked_at.desc())
    )
    return list(result.all())
