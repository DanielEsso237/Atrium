"""Arrhes d'une reservation : la regle de calcul vit dans `settings`.

Cle `reservation.deposit_rule`, portee GLOBAL, une des deux formes :

    {"mode": "FIXED", "amount": 20000}     somme fixe en FCFA
    {"mode": "PERCENT", "rate_bp": 3000}   30 % du sejour, en points de base

Absente ou illisible : pas d'arrhes exigees. Jamais de valeur en dur -- chaque
hotel a sa politique, et `settings` est replique : la tablette calcule le meme
montant hors ligne, a partir de la meme ligne.
"""

from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Setting
from app.models.enums import SettingScope

RULE_KEY = "reservation.deposit_rule"


def deposit_from_rule(rule: dict | None, stay_total: int) -> int:
    """Montant des arrhes pour un sejour de `stay_total` FCFA. Pure.

    Jamais negatif, jamais plus que le sejour : des arrhes superieures au prix
    feraient un avoir a rembourser, ce qui n'est plus des arrhes.
    """
    if not isinstance(rule, dict):
        return 0
    mode = rule.get("mode")
    if mode == "FIXED":
        amount = rule.get("amount")
    elif mode == "PERCENT":
        rate = rule.get("rate_bp")
        amount = stay_total * rate // 10_000 if isinstance(rate, int) else None
    else:
        return 0
    if not isinstance(amount, int) or amount <= 0:
        return 0
    return min(amount, stay_total)


async def deposit_rule(session: AsyncSession, hotel_id: uuid.UUID) -> dict | None:
    return await session.scalar(
        select(Setting.value).where(
            Setting.hotel_id == hotel_id,
            Setting.key == RULE_KEY,
            Setting.scope == SettingScope.GLOBAL,
            Setting.deleted_at.is_(None),
        )
    )
