"""Authentification (exigence 6.2) : connexion, rafraichissement, deconnexion.

Jeton d'acces court (JWT, 60 min) + jeton de rafraichissement long et opaque
(30 jours glissants, stocke hache dans `refresh_tokens`). En mode kiosque, la
tablette echange son jeton de rafraichissement avant l'expiration de l'acces :
un service de huit heures ne redemande jamais le mot de passe.

Cycle de vie d'une ligne `refresh_tokens` :

- `revoked_at` renseigne = **echange** (rotation) : le jeton a servi une
  fois. Il reste accepte `refresh_reuse_grace_seconds` pour absorber une
  reponse perdue sur le reseau ; apres, sa reutilisation signale un vol.
- ligne **supprimee** = invalide pour toujours (deconnexion, vol detecte,
  expiration). Pas de suppression logique ici : la table ne quitte jamais le
  serveur, aucune tablette n'a besoin de voir la suppression passer.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from sqlalchemy import delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.core.config import settings
from app.core.security import (
    create_access_token,
    hash_refresh_token,
    new_refresh_token,
    secret_accepte,
)
from app.db.session import get_session
from app.models import Device, RefreshToken, User
from app.schemas.auth import LoginIn, RefreshIn, TokenOut, UserOut

router = APIRouter(prefix="/auth", tags=["authentification"])

# Jetons echanges conserves un jour pour la detection de reutilisation, puis
# purges au fil des rafraichissements de l'utilisateur.
_ROTATED_RETENTION = dt.timedelta(days=1)


async def _issue_tokens(
    session: AsyncSession,
    user: User,
    device_id: uuid.UUID | None,
    user_agent: str | None,
    now: dt.datetime,
) -> TokenOut:
    plain, token_hash = new_refresh_token()
    session.add(
        RefreshToken(
            user_id=user.id,
            device_id=device_id,
            token_hash=token_hash,
            expires_at=now + dt.timedelta(days=settings.refresh_token_expire_days),
            user_agent=(user_agent or "")[:255] or None,
        )
    )
    return TokenOut(
        access_token=create_access_token(user.id),
        expires_in=settings.access_token_expire_minutes * 60,
        refresh_token=plain,
        refresh_expires_in=settings.refresh_token_expire_days * 86400,
    )


@router.post("/login", response_model=TokenOut)
async def login(
    payload: LoginIn, request: Request, session: AsyncSession = Depends(get_session)
) -> TokenOut:
    result = await session.execute(
        select(User).where(
            User.employee_code == payload.employee_code, User.deleted_at.is_(None)
        )
    )
    user = result.scalar_one_or_none()

    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Identifiant ou mot de passe incorrect.",
    )
    if user is None:
        raise invalid

    now = dt.datetime.now(dt.timezone.utc)
    if user.locked_until is not None and user.locked_until > now:
        raise HTTPException(
            status_code=status.HTTP_423_LOCKED,
            detail="Compte temporairement verrouille, reessayez plus tard.",
        )

    # Mot de passe **ou** code PIN : sur une tablette de comptoir que dix
    # agents se passent dans la journee, taper un mot de passe complet a chaque
    # releve est intenable -- c'est pour ca que l'ecran de connexion propose un
    # pave numerique. Le PIN etait hache et stocke depuis le debut, mais jamais
    # verifie : il ne fonctionnait donc qu'en mode hors ligne.
    #
    # Quatre chiffres se devinent, evidemment. Ce qui protege ici n'est pas la
    # longueur du secret mais le verrouillage au bout de cinq essais, quelques
    # lignes plus bas, et le fait que la tablette soit derriere un comptoir.
    if not secret_accepte(payload.password, user.password_hash, user.pin_hash):
        user.failed_login_count += 1
        if user.failed_login_count >= 5:
            user.locked_until = now + dt.timedelta(minutes=15)
        await session.commit()
        raise invalid

    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Compte desactive."
        )

    if payload.device_id is not None:
        device = await session.get(Device, payload.device_id)
        if device is None or device.hotel_id != user.hotel_id or device.deleted_at is not None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Appareil inconnu.")

    user.failed_login_count = 0
    user.locked_until = None
    user.last_login_at = now
    tokens = await _issue_tokens(
        session, user, payload.device_id, request.headers.get("user-agent"), now
    )
    await session.commit()
    return tokens


@router.post("/refresh", response_model=TokenOut)
async def refresh(
    payload: RefreshIn, request: Request, session: AsyncSession = Depends(get_session)
) -> TokenOut:
    """Echange un jeton de rafraichissement contre une nouvelle paire.

    La ligne est verrouillee le temps de l'echange : deux envois simultanes
    du meme jeton (double tap, nouvelle tentative reseau) passent l'un apres
    l'autre, le second tombe dans la fenetre de tolerance.
    """
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Session expiree, reconnectez-vous.",
        headers={"WWW-Authenticate": "Bearer"},
    )
    now = dt.datetime.now(dt.timezone.utc)
    token = await session.scalar(
        select(RefreshToken)
        .where(RefreshToken.token_hash == hash_refresh_token(payload.refresh_token))
        .with_for_update()
    )
    if token is None:
        raise unauthorized

    if token.expires_at <= now:
        await session.delete(token)
        await session.commit()
        raise unauthorized

    if token.revoked_at is not None:
        grace = dt.timedelta(seconds=settings.refresh_reuse_grace_seconds)
        if now - token.revoked_at > grace:
            # Jeton deja echange, presente bien apres : quelqu'un d'autre le
            # detient. On coupe toutes les sessions de cet appareil (ou de
            # l'utilisateur si le jeton n'etait rattache a aucun appareil).
            scope = RefreshToken.user_id == token.user_id
            if token.device_id is not None:
                scope = scope & (RefreshToken.device_id == token.device_id)
            await session.execute(delete(RefreshToken).where(scope))
            await session.commit()
            raise unauthorized

    user = await session.get(User, token.user_id)
    if (
        user is None
        or user.deleted_at is not None
        or not user.is_active
        or (user.locked_until is not None and user.locked_until > now)
    ):
        await session.delete(token)
        await session.commit()
        raise unauthorized

    if token.revoked_at is None:
        token.revoked_at = now

    # Menage opportuniste : les jetons expires ou echanges depuis longtemps
    # de cet utilisateur. Une requete indexee, et la table ne grossit pas.
    await session.execute(
        delete(RefreshToken).where(
            RefreshToken.user_id == user.id,
            or_(
                RefreshToken.expires_at <= now,
                RefreshToken.revoked_at < now - _ROTATED_RETENTION,
            ),
        )
    )
    tokens = await _issue_tokens(
        session, user, token.device_id, request.headers.get("user-agent"), now
    )
    await session.commit()
    return tokens


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def logout(payload: RefreshIn, session: AsyncSession = Depends(get_session)) -> Response:
    """Revoque le jeton de rafraichissement presente. Idempotent : un jeton

    inconnu repond aussi 204, pour ne rien apprendre a qui essaie des valeurs.
    Le jeton d'acces en cours expire de lui-meme (60 min au plus).
    """
    await session.execute(
        delete(RefreshToken).where(
            RefreshToken.token_hash == hash_refresh_token(payload.refresh_token)
        )
    )
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)) -> User:
    return user
