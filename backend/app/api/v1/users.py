"""Routes personnel : utilisateurs et roles (exigence 6.2 -- RBAC)."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.core.security import hash_secret
from app.db.session import get_session
from app.models import Role, User, UserRole
from app.schemas.auth import RoleOut
from app.schemas.users import PasswordReset, UserIn, UserOut, UserUpdate

router = APIRouter(tags=["personnel"])


async def _resolve_roles(session: AsyncSession, codes: list[str]) -> list[Role]:
    if not codes:
        return []
    result = await session.execute(select(Role).where(Role.code.in_(codes)))
    roles = list(result.scalars().all())
    missing = set(codes) - {r.code for r in roles}
    if missing:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"Role(s) inconnu(s) : {', '.join(sorted(missing))}",
        )
    return roles


async def _set_roles(session: AsyncSession, user_id: uuid.UUID, roles: list[Role]) -> None:
    """Remplace entierement les roles d'un utilisateur.

    `User.roles` est une relation `viewonly=True` (voir app/models/core.py) --
    elle se lit, mais s'ecrit uniquement via des lignes `UserRole` explicites.
    """
    await session.execute(delete(UserRole).where(UserRole.user_id == user_id))
    for role in roles:
        session.add(UserRole(user_id=user_id, role_id=role.id))


@router.get(
    "/roles",
    response_model=list[RoleOut],
    dependencies=[Depends(require_permission("users.read"))],
)
async def list_roles(session: AsyncSession = Depends(get_session)) -> list[Role]:
    """Catalogue des roles disponibles (pour peupler un menu deroulant)."""
    result = await session.execute(select(Role).order_by(Role.label))
    return list(result.scalars().all())


@router.get("/users", response_model=list[UserOut])
async def list_users(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("users.read")),
) -> list[User]:
    result = await session.execute(
        select(User)
        .where(User.hotel_id == user.hotel_id, User.deleted_at.is_(None))
        .order_by(User.last_name, User.first_name)
    )
    return list(result.scalars().all())


@router.post("/users", response_model=UserOut, status_code=status.HTTP_201_CREATED)
async def create_user(
    payload: UserIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("users.write")),
) -> User:
    roles = await _resolve_roles(session, payload.role_codes)
    new_user = User(
        hotel_id=user.hotel_id,
        employee_code=payload.employee_code,
        first_name=payload.first_name,
        last_name=payload.last_name,
        email=payload.email,
        phone=payload.phone,
        password_hash=hash_secret(payload.password),
        is_active=True,
        must_change_password=True,
    )
    session.add(new_user)
    try:
        await session.flush()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Ce code employe existe deja pour cet hotel."
        ) from exc

    await _set_roles(session, new_user.id, roles)
    await session.commit()
    await session.refresh(new_user, attribute_names=["roles"])
    return new_user


@router.get("/users/{user_id}", response_model=UserOut)
async def get_user(
    user_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("users.read")),
) -> User:
    target = await session.get(User, user_id)
    if target is None or target.hotel_id != user.hotel_id or target.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Utilisateur introuvable.")
    return target


@router.patch("/users/{user_id}", response_model=UserOut)
async def update_user(
    user_id: uuid.UUID,
    payload: UserUpdate,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("users.write")),
) -> User:
    target = await session.get(User, user_id)
    if target is None or target.hotel_id != user.hotel_id or target.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Utilisateur introuvable.")

    roles = await _resolve_roles(session, payload.role_codes)
    target.first_name = payload.first_name
    target.last_name = payload.last_name
    target.email = payload.email
    target.phone = payload.phone
    target.is_active = payload.is_active
    await _set_roles(session, target.id, roles)
    await session.commit()
    await session.refresh(target, attribute_names=["roles"])
    return target


@router.post("/users/{user_id}/reset-password", response_model=UserOut)
async def reset_password(
    user_id: uuid.UUID,
    payload: PasswordReset,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("users.write")),
) -> User:
    target = await session.get(User, user_id)
    if target is None or target.hotel_id != user.hotel_id or target.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Utilisateur introuvable.")

    target.password_hash = hash_secret(payload.new_password)
    target.must_change_password = True
    target.failed_login_count = 0
    target.locked_until = None
    await session.commit()
    await session.refresh(target, attribute_names=["roles"])
    return target
