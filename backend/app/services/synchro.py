"""Ce qui a change depuis la derniere synchronisation d'une tablette.

Une tablette relisait tout a chaque echange : vingt-neuf routes, des
centaines de lignes, meme quand rien n'avait bouge. Elle demande maintenant
d'abord *quelles tables* ont change, puis ne relit que celles-la, par leurs
routes habituelles -- avec leurs droits et leurs filtres, que rien ici ne
duplique.

**Le curseur est un instantane PostgreSQL**, pas un numero. `change_seq` est
pris a l'ecriture : deux transactions concurrentes deviennent visibles dans
le desordre, et un curseur numerique sauterait pour toujours la plus lente
(migration 0031). Un instantane dit exactement quelles transactions etaient
validees ; une ligne du journal est nouvelle pour la tablette si sa
transaction ne l'etait pas encore.
"""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass, field

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.base import Base

# xmin:xmax:xip1,xip2,...  -- le format texte de `pg_snapshot`.
_INSTANTANE = re.compile(r"^\d{1,19}:\d{1,19}:(\d{1,19}(,\d{1,19})*)?$")

# Au-dela, relire table par table coute plus qu'une synchronisation complete,
# et une tablette absente une semaine ne doit pas recevoir un journal entier.
LIMITE = 5000


def _instantane_valide(texte: str | None) -> bool:
    """Ce que PostgreSQL accepte comme `pg_snapshot`, verifie avant lui.

    Un curseur qu'il refuserait leverait une erreur au milieu de la requete
    (500) ; ici, il fait simplement tout relire.
    """
    if texte is None or not _INSTANTANE.match(texte):
        return False
    xmin, xmax, liste = texte.split(":")
    actives = [int(x) for x in liste.split(",")] if liste else []
    bornes = [int(xmin), int(xmax), *actives]
    if any(b >= 2**63 for b in bornes) or int(xmin) > int(xmax):
        return False
    return all(int(xmin) <= x < int(xmax) for x in actives) and actives == sorted(actives)


@dataclass
class Changements:
    # L'instantane a renvoyer la prochaine fois.
    curseur: str
    # Le curseur ne peut pas servir (absent, illisible, d'une autre base, ou
    # trop de retard) : la tablette relit tout, puis repart de `curseur`.
    complet: bool
    tables: set[str] = field(default_factory=set)
    # Lignes retirees (`deleted_at`) : les routes de liste ne les rendent
    # plus, la tablette ne les verrait jamais partir sans cela.
    retirees: dict[str, set[uuid.UUID]] = field(default_factory=dict)


def _colonnes(table: str) -> set[str]:
    t = Base.metadata.tables.get(table)
    return set() if t is None else {c.name for c in t.columns}


async def changements_depuis(
    session: AsyncSession, depuis: str | None, hotel_id: uuid.UUID
) -> Changements:
    """Les tables modifiees depuis l'instantane [depuis], pour cet hotel.

    Sans curseur valable, `complet` : la tablette doit tout relire. Elle
    demande le curseur **avant** de relire, jamais apres -- un changement
    valide entre les deux lui reviendrait alors une seconde fois, sans
    dommage, au lieu de lui echapper.
    """
    if not _instantane_valide(depuis):
        curseur = (await session.execute(text("SELECT pg_current_snapshot()::text"))).scalar_one()
        return Changements(curseur=curseur, complet=True)

    # Une seule requete : l'instantane rendu est celui-la meme qui a lu le
    # journal. Deux requetes laisseraient passer entre elles une validation
    # que le curseur dirait vue sans qu'elle ait ete lue.
    lignes = (
        await session.execute(
            text(
                """
                WITH courant AS (
                    SELECT pg_current_snapshot() AS s,
                           -- Passe en texte : le pilote ne sait pas encoder un pg_snapshot.
                           CAST(CAST(:depuis AS text) AS pg_snapshot) AS d
                )
                SELECT c.s::text AS curseur,
                       pg_snapshot_xmax(c.d) > pg_snapshot_xmax(c.s) AS d_ailleurs,
                       l.entity_table, l.entity_id
                  FROM courant c
                  LEFT JOIN LATERAL (
                        SELECT entity_table, entity_id, seq
                          FROM sync_change_log
                         WHERE xid >= pg_snapshot_xmin(c.d)
                           AND NOT pg_visible_in_snapshot(xid, c.d)
                         ORDER BY seq
                         LIMIT :limite
                       ) l ON true
                """
            ),
            {"depuis": depuis, "limite": LIMITE + 1},
        )
    ).all()

    curseur = lignes[0].curseur
    # Un curseur venu d'une base reinstallee (ou fabrique) designe des
    # transactions qui n'existent pas encore ici.
    if lignes[0].d_ailleurs or len(lignes) > LIMITE:
        return Changements(curseur=curseur, complet=True)

    par_table: dict[str, set[uuid.UUID]] = {}
    for ligne in lignes:
        if ligne.entity_table is not None:
            par_table.setdefault(ligne.entity_table, set()).add(ligne.entity_id)

    resultat = Changements(curseur=curseur, complet=False)
    for table, ids in par_table.items():
        colonnes = _colonnes(table)
        if "hotel_id" not in colonnes:
            # Pas de quoi verifier l'hotel (lignes d'ardoise, de sejour...) :
            # la table compte. Au pire, la tablette relit pour rien.
            resultat.tables.add(table)
            continue
        retire = "deleted_at IS NOT NULL" if "deleted_at" in colonnes else "false"
        # Le nom de table vient du journal, ecrit par nos declencheurs, et
        # n'est accepte que s'il figure dans les modeles.
        trouvees = (
            await session.execute(
                text(
                    f"SELECT id, {retire} AS retiree FROM {table} "
                    "WHERE id = ANY(:ids) AND hotel_id = :hotel"
                ),
                {"ids": list(ids), "hotel": hotel_id},
            )
        ).all()
        # Rien de cet hotel : la table ne le concerne pas. Une suppression
        # physique n'y laisse rien non plus ; l'application n'en fait pas.
        if not trouvees:
            continue
        resultat.tables.add(table)
        retirees = {t.id for t in trouvees if t.retiree}
        if retirees:
            resultat.retirees[table] = retirees
    return resultat
