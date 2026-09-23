"""Date hoteliere courante d'un hotel.

Un hotel ne change pas de journee a minuit : la nuit du 12 au 13 appartient
au 12 tant que la bascule (`hotels.day_rollover_hour`, 6 h par defaut) n'est
pas passee. Un encaissement a 2 h du matin fait donc partie du chiffre
d'affaires de la veille, et c'est exactement ce que la reception attend en
lisant le rapport du lendemain.

Deux erreurs que ce module existe pour rendre impossibles :

1. `dt.date.today()` renvoie la date **du serveur**. Avec un hotel a Abidjan
   et un serveur en Europe, les deux ne sont pas d'accord une partie de la
   journee -- et personne ne voit le probleme avant de comparer une caisse
   avec un rapport.
2. Meme dans le bon fuseau, minuit n'est pas la bascule. Sans
   `day_rollover_hour`, toute la fin de service bascule sur le jour suivant.
"""

from __future__ import annotations

import datetime as dt
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Hotel

# Repli si `hotels.timezone` contient une zone inconnue de la base IANA
# installee : on prefere une date coherente avec le defaut du modele a une
# exception qui bloquerait un encaissement.
_FUSEAU_DEFAUT = "Africa/Abidjan"


def business_date_for(
    instant: dt.datetime, timezone_name: str, day_rollover_hour: int
) -> dt.date:
    """Date hoteliere de `instant` pour un hotel donne.

    Fonction pure, sans base : c'est elle qui porte la regle, et c'est elle
    qu'on teste. `instant` peut etre naif ; il est alors lu comme de l'UTC,
    parce que tout le code de l'API construit ses horodatages avec
    `dt.datetime.now(dt.timezone.utc)`.
    """
    if instant.tzinfo is None:
        instant = instant.replace(tzinfo=dt.timezone.utc)
    try:
        zone = ZoneInfo(timezone_name)
    except (ZoneInfoNotFoundError, ValueError):
        zone = ZoneInfo(_FUSEAU_DEFAUT)

    local = instant.astimezone(zone)
    if local.hour < day_rollover_hour:
        return local.date() - dt.timedelta(days=1)
    return local.date()


async def current_business_date(session: AsyncSession, hotel_id: uuid.UUID) -> dt.date:
    """Date hoteliere de maintenant, pour cet hotel.

    Une requete par appel. Les routes qui en ont besoin plusieurs fois
    (enregistrer une charge puis recalculer un total) la lisent une fois et
    se passent la valeur, plutot que de rappeler cette fonction.
    """
    row = (
        await session.execute(
            select(Hotel.timezone, Hotel.day_rollover_hour).where(Hotel.id == hotel_id)
        )
    ).first()
    if row is None:
        # Hotel introuvable : les routes appelantes ont deja verifie que
        # l'utilisateur appartient a un hotel, donc on est ici sur une base
        # incoherente. Le defaut du modele vaut mieux qu'une 500.
        return business_date_for(dt.datetime.now(dt.timezone.utc), _FUSEAU_DEFAUT, 6)

    timezone_name, rollover = row
    return business_date_for(dt.datetime.now(dt.timezone.utc), timezone_name, rollover)
