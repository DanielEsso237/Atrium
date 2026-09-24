"""Numerotation par hotel : factures, reservations, folios, commandes, clients.

Une seule regle pour tous les numeros lisibles du projet. Avant ce module,
seules les factures passaient par `number_sequences` ; les autres faisaient
`COUNT(*) + 1`, ce qui donne le meme numero a deux requetes simultanees (la
seconde echoue alors sur la contrainte unique) et recycle un numero des qu'une
ligne disparait.

Une seule instruction SQL par numero :

    INSERT ... ON CONFLICT (hotel_id, scope, period)
    DO UPDATE SET current_value = current_value + 1
    RETURNING current_value, prefix, padding

- premiere utilisation d'une portee : la ligne est creee a 1, sans etape
  prealable ni course entre deux premiers appels ;
- ensuite : increment atomique. PostgreSQL verrouille la ligne jusqu'a la fin
  de la transaction appelante, donc deux emissions concurrentes sont
  serialisees et ne peuvent pas lire la meme valeur ;
- le numero vit dans la transaction de l'appelant : si elle echoue, l'increment
  est annule avec elle. Pas de trou -- c'est ce qu'exige une facture (F1.4),
  et ca ne coute rien aux autres portees.

Le verrou est tenu jusqu'au commit : appeler `next_number` le plus tard
possible dans la route, apres les controles qui peuvent echouer.
"""

from __future__ import annotations

import uuid
from enum import Enum

from sqlalchemy import func
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import NumberSequence


class Scope(str, Enum):
    """Portees de numerotation et leur prefixe par defaut.

    Les prefixes reprennent exactement les formats deja emis par l'API, pour
    que les numeros existants et les nouveaux se suivent.
    """

    INVOICE = "INVOICE"
    RESERVATION = "RESERVATION"
    FOLIO = "FOLIO"
    ORDER = "ORDER"
    GUEST = "GUEST"
    MAINTENANCE_TICKET = "MAINTENANCE_TICKET"


DEFAULT_PREFIXES: dict[Scope, str] = {
    Scope.INVOICE: "FA-",
    Scope.RESERVATION: "RES-",
    Scope.FOLIO: "FOL-",
    Scope.ORDER: "ORD-",
    Scope.GUEST: "CLI-",
    Scope.MAINTENANCE_TICKET: "TCK-",
}
DEFAULT_PADDING = 6


def format_number(prefix: str | None, value: int, padding: int) -> str:
    """`("RES-", 42, 6)` -> `"RES-000042"`. Pure, testee sans base."""
    return f"{prefix or ''}{value:0{padding}d}"


async def next_number(
    session: AsyncSession,
    hotel_id: uuid.UUID,
    scope: Scope,
    *,
    period: str = "ALL",
) -> str:
    """Attribue le prochain numero de `scope` pour cet hotel.

    Le prefixe et le remplissage ne servent qu'a la creation de la ligne ;
    ensuite, ce sont ceux stockes dans `number_sequences` qui font foi, ce qui
    permet a un hotel de changer de format sans toucher au code.
    """
    stmt = insert(NumberSequence).values(
        hotel_id=hotel_id,
        scope=scope.value,
        period=period,
        prefix=DEFAULT_PREFIXES[scope],
        padding=DEFAULT_PADDING,
        current_value=1,
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=["hotel_id", "scope", "period"],
        set_={
            "current_value": NumberSequence.current_value + 1,
            "updated_at": func.now(),
        },
    ).returning(NumberSequence.current_value, NumberSequence.prefix, NumberSequence.padding)

    value, prefix, padding = (await session.execute(stmt)).one()
    return format_number(prefix, value, padding)
