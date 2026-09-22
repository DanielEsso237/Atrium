"""Hachage des secrets et emission/verification des jetons JWT.

Trois voies d'authentification cote utilisateur (exigence 6.2 du cahier des
charges) : mot de passe, code PIN, badge. Seules les deux premieres sont
hachees ici -- un badge se lit, il ne se "prouve" pas par connaissance d'un
secret.
"""

from __future__ import annotations

import datetime as dt
import uuid

from jose import JWTError, jwt
from passlib.context import CryptContext

from app.core.config import settings

_pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_secret(plain: str) -> str:
    """Hache un mot de passe ou un code PIN (meme mecanisme, meme cout)."""
    return _pwd_context.hash(plain)


def verify_secret(plain: str, hashed: str | None) -> bool:
    if not hashed:
        return False
    return _pwd_context.verify(plain, hashed)


def create_access_token(user_id: uuid.UUID) -> str:
    expire = dt.datetime.now(dt.timezone.utc) + dt.timedelta(
        minutes=settings.access_token_expire_minutes
    )
    payload = {"sub": str(user_id), "exp": expire, "type": "access"}
    return jwt.encode(payload, settings.secret_key, algorithm=settings.algorithm)


def decode_access_token(token: str) -> uuid.UUID | None:
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    except JWTError:
        return None
    if payload.get("type") != "access":
        return None
    sub = payload.get("sub")
    if sub is None:
        return None
    try:
        return uuid.UUID(sub)
    except ValueError:
        return None
