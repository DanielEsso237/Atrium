"""Authentification (exigence 6.2) : connexion par mot de passe, profil courant."""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.core.config import settings
from app.core.security import create_access_token, verify_secret
from app.db.session import get_session
from app.models import User
from app.schemas.auth import LoginIn, TokenOut, UserOut

router = APIRouter(prefix="/auth", tags=["authentification"])


@router.post("/login", response_model=TokenOut)
async def login(
    payload: LoginIn, session: AsyncSession = Depends(get_session)
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

    if not verify_secret(payload.password, user.password_hash):
        user.failed_login_count += 1
        if user.failed_login_count >= 5:
            user.locked_until = now + dt.timedelta(minutes=15)
        await session.commit()
        raise invalid

    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Compte desactive."
        )

    user.failed_login_count = 0
    user.locked_until = None
    user.last_login_at = now
    await session.commit()

    token = create_access_token(user.id)
    return TokenOut(
        access_token=token,
        expires_in=settings.access_token_expire_minutes * 60,
    )


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)) -> User:
    return user
