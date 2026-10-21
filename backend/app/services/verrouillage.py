"""Cinq codes faux bloquent un compte.

Un PIN de quatre chiffres se devine : ce qui le protege, c'est qu'on ne peut
pas l'essayer longtemps. Decision du 21 octobre : au cinquieme code faux,
l'agent est **bloque jusqu'a ce qu'un responsable le debloque** -- en lui
faisant choisir un nouveau code (`POST /auth/reset-secret`) ou depuis
l'administration (`reset-pin`, `reset-password`). Attendre un quart d'heure
ne suffit plus : un agent bloque doit aller voir quelqu'un.

Sauf pour les responsables eux-memes (`users.reset_secret`). Personne
au-dessus d'eux ne les debloquerait : le dernier administrateur se serait
ferme la porte. Eux gardent l'ancienne regle, quinze minutes d'attente.

Les memes colonnes qu'avant, `failed_login_count` et `locked_until`, lues
autrement : rien a migrer, et la tablette applique la meme regle hors ligne.
"""

from __future__ import annotations

import datetime as dt

from app.api.deps import permission_codes
from app.models import User

ECHECS_MAX = 5
ATTENTE_RESPONSABLE = dt.timedelta(minutes=15)
DROIT_REINITIALISER = "users.reset_secret"


def est_responsable(user: User) -> bool:
    return DROIT_REINITIALISER in permission_codes(user)


def est_verrouille(user: User, now: dt.datetime) -> bool:
    if user.failed_login_count < ECHECS_MAX:
        return False
    if est_responsable(user):
        return user.locked_until is not None and user.locked_until > now
    return True


def compter_echec(user: User, now: dt.datetime) -> None:
    user.failed_login_count += 1
    if user.failed_login_count >= ECHECS_MAX and est_responsable(user):
        user.locked_until = now + ATTENTE_RESPONSABLE


def debloquer(user: User) -> None:
    user.failed_login_count = 0
    user.locked_until = None
