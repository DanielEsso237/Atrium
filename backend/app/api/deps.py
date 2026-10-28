"""Dependances FastAPI partagees entre tous les routeurs.

Regroupees ici (plutot que dans chaque routeur) parce que l'authentification
et le controle de role concernent tous les domaines metier, pas un seul.
"""

from __future__ import annotations

import datetime as dt

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.security import decode_access_claims
from app.db.session import get_session
from app.models import AuditLog, User

# tokenUrl ne sert qu'a la doc Swagger (bouton "Authorize") ; le endpoint reel
# est POST {api_prefix}/auth/login, qui prend du JSON et pas un formulaire.
oauth2_scheme = OAuth2PasswordBearer(tokenUrl=f"{settings.api_prefix}/auth/login")


async def get_current_user(
    request: Request,
    token: str = Depends(oauth2_scheme),
    session: AsyncSession = Depends(get_session),
) -> User:
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Identifiants invalides ou expires.",
        headers={"WWW-Authenticate": "Bearer"},
    )
    claims = decode_access_claims(token)
    if claims is None:
        raise unauthorized
    user_id, approver_id, device_id = claims

    # User.roles et Role.permissions sont deja lazy="selectin" sur le modele :
    # une seule requete supplementaire charge tout l'arbre role -> permissions.
    result = await session.execute(
        select(User).where(User.id == user_id, User.deleted_at.is_(None))
    )
    user = result.scalar_one_or_none()
    # Un jeton delegue sert justement a l'agent qui ne repasse pas -- parti,
    # parfois desactive : ses ecritures restent a remonter.
    if user is None or (not user.is_active and approver_id is None):
        raise unauthorized
    if approver_id is not None:
        _tracer_delegation(request, session, user, approver_id, device_id)
    return user


def _tracer_delegation(
    request: Request,
    session: AsyncSession,
    user: User,
    approver_id,
    device_id,
) -> None:
    """Un jeton delegue ne sert qu'a remonter des ecritures, et chacune se
    trace au nom du responsable qui l'a permis.

    La trace part avec l'ecriture, dans la meme session : une ecriture
    refusee n'en laisse pas.
    """
    if request.method == "GET" or request.url.path.startswith(
        f"{settings.api_prefix}/auth"
    ):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "Un envoi pour un collegue ne sert qu'a remonter ses ecritures.",
        )
    session.add(
        AuditLog(
            user_id=approver_id,
            device_id=device_id,
            entity_table="outbox_entries",
            action="SYNC_DELEGATED_WRITE",
            after={
                "on_behalf_of": str(user.id),
                "method": request.method,
                "path": request.url.path,
            },
            occurred_at=dt.datetime.now(dt.timezone.utc),
        )
    )


def permission_codes(user: User) -> set[str]:
    """Codes de permission effectifs de l'utilisateur, tous roles confondus.

    Partage entre `require_permission` et les routes qui ont besoin d'une
    verification conditionnelle au milieu de leur logique (ex: une charge de
    type DISCOUNT exige `folio.discount` en plus de `folio.write`, voir
    app/api/v1/billing.py) plutot que d'un simple garde-fou en entree de route.
    """
    return {perm.code for role in user.roles for perm in role.permissions}


def require_any_permission(*codes: str):
    """Comme `require_permission`, mais l'une des permissions suffit.

    Pour une route que deux metiers atteignent a des titres differents : la
    reception porte une charge avec folio.write, le comptoir avec
    folio.charge, qui ne permet ni d'encaisser ni de clore.
    """

    async def _check(user: User = Depends(get_current_user)) -> User:
        if not permission_codes(user) & set(codes):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Permission manquante : {' ou '.join(codes)}",
            )
        return user

    return _check


def require_permission(code: str):
    """Fabrique une dependance qui exige la permission `code` (RBAC, 6.2).

    A poser sur chaque route qui en a besoin :
    `Depends(require_permission("reservation.create"))`. ADMIN n'est jamais
    code en dur ici : c'est un role comme un autre, seede avec toutes les
    permissions -- la regle d'autorisation reste uniforme pour tout le monde.
    """

    async def _check(user: User = Depends(get_current_user)) -> User:
        if code not in permission_codes(user):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Permission manquante : {code}",
            )
        return user

    return _check
