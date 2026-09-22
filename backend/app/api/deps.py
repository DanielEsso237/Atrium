"""Dependances FastAPI partagees entre tous les routeurs.

Regroupees ici (plutot que dans chaque routeur) parce que l'authentification
et le controle de role concernent tous les domaines metier, pas un seul.
"""

from __future__ import annotations

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.security import decode_access_token
from app.db.session import get_session
from app.models import User

# tokenUrl ne sert qu'a la doc Swagger (bouton "Authorize") ; le endpoint reel
# est POST {api_prefix}/auth/login, qui prend du JSON et pas un formulaire.
oauth2_scheme = OAuth2PasswordBearer(tokenUrl=f"{settings.api_prefix}/auth/login")


async def get_current_user(
    token: str = Depends(oauth2_scheme),
    session: AsyncSession = Depends(get_session),
) -> User:
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Identifiants invalides ou expires.",
        headers={"WWW-Authenticate": "Bearer"},
    )
    user_id = decode_access_token(token)
    if user_id is None:
        raise unauthorized

    # User.roles et Role.permissions sont deja lazy="selectin" sur le modele :
    # une seule requete supplementaire charge tout l'arbre role -> permissions.
    result = await session.execute(
        select(User).where(User.id == user_id, User.deleted_at.is_(None))
    )
    user = result.scalar_one_or_none()
    if user is None or not user.is_active:
        raise unauthorized
    return user


def permission_codes(user: User) -> set[str]:
    """Codes de permission effectifs de l'utilisateur, tous roles confondus.

    Partage entre `require_permission` et les routes qui ont besoin d'une
    verification conditionnelle au milieu de leur logique (ex: une charge de
    type DISCOUNT exige `folio.discount` en plus de `folio.write`, voir
    app/api/v1/billing.py) plutot que d'un simple garde-fou en entree de route.
    """
    return {perm.code for role in user.roles for perm in role.permissions}


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
