"""Points de vente accessibles a un agent (`user_outlets`).

Un agent sans aucun rattachement voit tous les points de vente : c'est
l'etat de tout compte a sa creation, et le rendre aveugle d'office ferait
d'un oubli de configuration une panne au service. Des qu'il est rattache a
un point de vente, il ne voit plus que les siens.
"""

from __future__ import annotations

import uuid

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import User, UserOutlet

# Chaque hotel a d'office un point de vente « Restaurant » : c'est lui qui
# portera la carte facturee sur l'ardoise d'une chambre. Son *code* est
# l'identite que tout le monde retrouve (tablette, seed, migration) ; son
# libelle, lui, peut etre change a l'administration. D'ou l'interdiction de
# le renommer ou de le desactiver (voir `update_outlet`).
DEFAULT_OUTLET_CODE = "RESTO"
DEFAULT_OUTLET_LABEL = "Restaurant"


async def allowed_outlet_ids(session: AsyncSession, user: User) -> set[uuid.UUID] | None:
    """Les points de vente de l'agent, ou None s'il n'est rattache a aucun (tous)."""
    ids = set(
        (
            await session.execute(
                select(UserOutlet.outlet_id).where(UserOutlet.user_id == user.id)
            )
        ).scalars()
    )
    return ids or None


async def ensure_outlet_allowed(
    session: AsyncSession, user: User, outlet_id: uuid.UUID
) -> None:
    allowed = await allowed_outlet_ids(session, user)
    if allowed is not None and outlet_id not in allowed:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "Vous n'etes pas rattache a ce point de vente."
        )
