"""Reglages de l'etablissement : aujourd'hui, la regle des arrhes.

La regle vit dans `settings`, cle `reservation.deposit_rule`, et
`services/deposit.py` la lisait deja -- mais rien ne permettait de l'ecrire
depuis l'application. L'ecran d'administration la fixe ici.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user, require_permission
from app.db.session import get_session
from app.models import Setting, User
from app.models.enums import SettingScope
from app.schemas.settings import DepositRule, DepositRuleOut
from app.services.deposit import RULE_KEY

router = APIRouter(prefix="/settings", tags=["reglages"])


async def _ligne(session: AsyncSession, user: User) -> Setting | None:
    # `scope_id` nul : la contrainte d'unicite ne joue pas sur NULL en
    # PostgreSQL, d'ou la lecture avant ecriture plutot qu'un upsert.
    return await session.scalar(
        select(Setting).where(
            Setting.hotel_id == user.hotel_id,
            Setting.key == RULE_KEY,
            Setting.scope == SettingScope.GLOBAL,
            Setting.scope_id.is_(None),
            Setting.deleted_at.is_(None),
        )
    )


@router.get("/deposit-rule", response_model=DepositRuleOut)
async def get_deposit_rule(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> DepositRuleOut:
    """Ouverte a tout agent : la reception en a besoin pour calculer les arrhes.

    Un droit dedie ferait echouer la descente des agents qui ne l'ont pas.
    """
    ligne = await _ligne(session, user)
    return DepositRuleOut(rule=ligne.value if ligne is not None else None)


@router.put("/deposit-rule", response_model=DepositRuleOut)
async def put_deposit_rule(
    payload: DepositRule,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("users.write")),
) -> DepositRuleOut:
    """Fixe la regle. Rejouable : renvoyer la meme regle ne change rien."""
    valeur = payload.as_setting()
    ligne = await _ligne(session, user)
    if ligne is None:
        ligne = Setting(
            hotel_id=user.hotel_id,
            key=RULE_KEY,
            scope=SettingScope.GLOBAL,
            label="Regle des arrhes",
        )
        session.add(ligne)
    ligne.value = valeur
    await session.commit()
    return DepositRuleOut(rule=valeur)


@router.delete("/deposit-rule", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def delete_deposit_rule(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("users.write")),
) -> None:
    """Plus d'arrhes par defaut. Sans regle, rien n'est exige (voir deposit.py)."""
    ligne = await _ligne(session, user)
    if ligne is not None:
        ligne.value = None
        await session.commit()
