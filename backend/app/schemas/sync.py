"""Schemas de la synchronisation par changements."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, Field


class SyncChangesOut(BaseModel):
    """Ce qu'une tablette doit relire depuis son dernier curseur.

    Des noms de tables, pas les lignes : la tablette relit ces tables par
    leurs routes habituelles, qui appliquent deja les droits et le perimetre
    de l'agent (un barman ne lit que ses points de vente).
    """

    cursor: str = Field(
        description="Instantane PostgreSQL a renvoyer en `since` au prochain appel"
    )
    full_resync: bool = Field(
        description="Le curseur ne sert pas (absent, illisible, trop ancien) : tout relire"
    )
    tables: list[str] = Field(
        default_factory=list, description="Tables modifiees, par ordre alphabetique"
    )
    removed: dict[str, list[uuid.UUID]] = Field(
        default_factory=dict,
        description="Lignes retirees (deleted_at), que les routes de liste ne rendent plus",
    )
