"""Garder le schema de la base de test a jour, sans la pilonner.

Le montage ne reconstruit plus le schema a chaque test (voir `conftest.py` :
cela a coute une base de developpement). Il se contentait de `create_all`,
qui cree les tables absentes mais **n'ajoute jamais une colonne a une table
qui existe**. Toute colonne ajoutee au modele apres la creation de
`atrium_test` y manquait donc, et les tests tombaient en
`UndefinedColumnError` sans que le code teste y soit pour rien --
`guests.credit_limit` l'a montre le 29 septembre.

Le compromis : comparer le schema aux modeles **une fois par session** de
tests, et ne reconstruire que s'il a derive. Une comparaison, c'est une
lecture du catalogue ; une reconstruction, soixante tables recreees une seule
fois, pas a chaque test.
"""

from __future__ import annotations

from sqlalchemy import MetaData, inspect, text
from sqlalchemy.engine import Connection, make_url


def ecarts_de_schema(
    modele: dict[str, set[str]], base: dict[str, set[str]]
) -> list[str]:
    """Les differences qui feraient echouer un test, en clair.

    Une table absente de la base n'en fait pas partie : `create_all` la cree.
    Une colonne manquante casse les ecritures ; une colonne en trop aussi,
    des qu'elle est obligatoire et que le modele ne la remplit plus.
    """
    ecarts = []
    for table, colonnes in sorted(modele.items()):
        if table not in base:
            continue
        for c in sorted(colonnes - base[table]):
            ecarts.append(f"{table}.{c} manque dans la base")
        for c in sorted(base[table] - colonnes):
            ecarts.append(f"{table}.{c} n'existe plus dans le modele")
    return ecarts


def aligner_schema(conn: Connection, metadata: MetaData) -> list[str]:
    """Reconstruit le schema s'il a derive des modeles ; renvoie les ecarts.

    `DROP SCHEMA ... CASCADE` plutot que `drop_all` : il emporte aussi les
    tables et les types qu'aucun modele ne connait plus, et qui bloqueraient
    une suppression table par table.
    """
    inspecteur = inspect(conn)
    existantes = set(inspecteur.get_table_names())
    modele = {t.name: {c.name for c in t.columns} for t in metadata.sorted_tables}
    base = {
        t: {c["name"] for c in inspecteur.get_columns(t)}
        for t in modele
        if t in existantes
    }

    ecarts = ecarts_de_schema(modele, base)
    if ecarts:
        conn.execute(text("DROP SCHEMA public CASCADE"))
        conn.execute(text("CREATE SCHEMA public"))
    metadata.create_all(conn)
    return ecarts


def verifier_base_de_test(url: str) -> None:
    """Refuse toute base dont le nom ne finit pas par `_test`.

    Le montage vide toutes les tables a chaque test, et peut desormais
    detruire le schema entier. Pointer `TEST_DATABASE_URL` sur `atrium` par
    megarde effacerait la base de developpement : on s'arrete avant.
    """
    nom = make_url(url).database or ""
    if not nom.endswith("_test"):
        raise RuntimeError(
            f"TEST_DATABASE_URL vise la base « {nom} ». Le montage des tests "
            "la viderait : seule une base dont le nom finit par `_test` est "
            "acceptee."
        )
