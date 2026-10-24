"""Ce qu'une tablette doit relire, sans tout relire.

La descente relisait vingt-neuf routes a chaque echange, meme quand rien
n'avait change : par ngrok, une quinzaine de secondes. La tablette demande
ici quelles tables ont bouge depuis son curseur, puis ne relit que celles-la.
Quand rien n'a change -- le cas le plus frequent --, un seul aller-retour.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.db.session import get_session
from app.models import User
from app.schemas.sync import SyncChangesOut
from app.services.synchro import changements_depuis

router = APIRouter(prefix="/sync", tags=["synchronisation"])


@router.get("/changes", response_model=SyncChangesOut)
async def sync_changes(
    since: str | None = Query(
        default=None,
        max_length=4000,
        description="Le `cursor` du dernier appel ; absent = premiere synchronisation",
    ),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> SyncChangesOut:
    """Les tables modifiees depuis `since`, et le curseur suivant.

    Tout agent connecte : la reponse ne contient que des noms de tables et
    des identifiants de lignes retirees, rien qu'un droit protege. Les
    lignes elles-memes se relisent par leurs routes, sous leurs droits.
    """
    c = await changements_depuis(session, since, user.hotel_id)
    return SyncChangesOut(
        cursor=c.curseur,
        full_resync=c.complet,
        tables=sorted(c.tables),
        removed={t: sorted(ids) for t, ids in sorted(c.retirees.items())},
    )
