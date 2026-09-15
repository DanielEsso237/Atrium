"""Generation d'UUID v7.

Les cles primaires sont generees par le client (tablette) et non par le serveur :
c'est ce qui permet a une tablette hors ligne de creer une reservation, de
l'imprimer et de la facturer sans jamais attendre un aller-retour reseau.

UUID v7 plutot que v4 parce que les 48 premiers bits sont l'horodatage
Unix en millisecondes : les cles restent croissantes dans le temps, donc les
insertions se font en fin d'index B-tree au lieu de fragmenter l'arbre.

Python 3.11 n'expose pas encore `uuid.uuid7()` (arrive en 3.14), d'ou cette
implementation conforme a la RFC 9562.
"""

from __future__ import annotations

import os
import time
import uuid

__all__ = ["uuid7", "uuid7_at"]


def uuid7_at(timestamp_ms: int) -> uuid.UUID:
    """Construit un UUID v7 pour un horodatage donne (en millisecondes)."""
    # 48 bits d'horodatage | 4 bits de version | 12 bits alea
    # | 2 bits de variante | 62 bits alea
    rand = os.urandom(10)

    value = (timestamp_ms & 0xFFFFFFFFFFFF) << 80
    value |= 0x7 << 76  # version 7
    value |= (int.from_bytes(rand[:2], "big") & 0xFFF) << 64
    value |= 0b10 << 62  # variante RFC 4122
    value |= int.from_bytes(rand[2:], "big") & ((1 << 62) - 1)

    return uuid.UUID(int=value)


def uuid7() -> uuid.UUID:
    """UUID v7 pour l'instant present."""
    return uuid7_at(time.time_ns() // 1_000_000)
