"""Hachage des secrets et emission/verification des jetons JWT.

Trois voies d'authentification cote utilisateur (exigence 6.2 du cahier des
charges) : mot de passe, code PIN, badge. Seules les deux premieres sont
hachees ici -- un badge se lit, il ne se "prouve" pas par connaissance d'un
secret.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import secrets
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


def secret_accepte(plain: str, password_hash: str | None, pin_hash: str | None) -> bool:
    """Le secret saisi ouvre-t-il la session ?

    Mot de passe **ou** code PIN, sans que l'agent ait a dire lequel : sur une
    tablette de comptoir, l'ecran de connexion propose un pave numerique et un
    champ mot de passe, et le serveur n'a pas besoin de savoir lequel a servi.

    Un compte sans PIN (`pin_hash` nul) n'est pas pour autant ouvert :
    `verify_secret` refuse un hachage absent. C'est le cas par defaut de tout
    compte cree par l'administration.
    """
    return verify_secret(plain, password_hash) or verify_secret(plain, pin_hash)


def create_access_token(user_id: uuid.UUID) -> str:
    expire = dt.datetime.now(dt.timezone.utc) + dt.timedelta(
        minutes=settings.access_token_expire_minutes
    )
    payload = {"sub": str(user_id), "exp": expire, "type": "access"}
    return jwt.encode(payload, settings.secret_key, algorithm=settings.algorithm)


# Assez pour vider une file, pas pour s'en servir de session.
DUREE_DELEGATION = dt.timedelta(minutes=10)


def create_delegated_token(
    author_id: uuid.UUID, approver_id: uuid.UUID, device_id: uuid.UUID | None
) -> str:
    """Un jeton au nom d'un agent absent, delivre sur le code d'un responsable.

    L'ecriture d'un collegue restee sur une tablette se juge avec **ses**
    droits : un encaissement tombe dans sa caisse, pas dans celle du
    responsable. `act` dit qui l'a permis (RFC 8693) ; chaque ecriture faite
    avec ce jeton se trace a son nom (`app/api/deps.py`). Court, et sans
    jeton de rafraichissement.
    """
    payload = {
        "sub": str(author_id),
        "act": str(approver_id),
        "exp": dt.datetime.now(dt.timezone.utc) + DUREE_DELEGATION,
        "type": "access",
    }
    if device_id is not None:
        payload["dev"] = str(device_id)
    return jwt.encode(payload, settings.secret_key, algorithm=settings.algorithm)


def new_refresh_token() -> tuple[str, str]:
    """Jeton de rafraichissement opaque : (valeur a remettre au client, hachage).

    256 bits aleatoires : un SHA-256 suffit a proteger la table (rien a
    deviner par force brute, contrairement a un mot de passe), et il se
    retrouve par egalite -- donc par index -- sans bcrypt ligne a ligne.
    """
    plain = secrets.token_urlsafe(32)
    return plain, hash_refresh_token(plain)


def hash_refresh_token(plain: str) -> str:
    return hashlib.sha256(plain.encode()).hexdigest()


def decode_access_token(token: str) -> uuid.UUID | None:
    claims = decode_access_claims(token)
    return None if claims is None else claims[0]


def decode_access_claims(
    token: str,
) -> tuple[uuid.UUID, uuid.UUID | None, uuid.UUID | None] | None:
    """(agent, responsable qui a delegue, tablette) ; les deux derniers ne
    sont poses que sur un jeton delegue."""
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    except JWTError:
        return None
    if payload.get("type") != "access":
        return None
    try:
        sub = uuid.UUID(payload["sub"])
        act = uuid.UUID(payload["act"]) if payload.get("act") else None
        dev = uuid.UUID(payload["dev"]) if payload.get("dev") else None
    except (KeyError, TypeError, ValueError):
        return None
    return sub, act, dev
