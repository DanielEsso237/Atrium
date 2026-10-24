"""Le journal des changements note la transaction qui a ecrit chaque ligne.

`change_seq` est pris a l'ecriture, pas a la validation : deux transactions
concurrentes deviennent visibles dans le desordre. A ecrit le n° 740, B le
n° 745 et valide aussitot ; une tablette qui lit a cet instant retient « tout
jusqu'a 745 » et ne verra jamais le 740, valide une seconde plus tard. Le
paragraphe 0.3 du modele de donnees promettait l'inverse.

Le curseur d'une tablette devient donc un **instantane PostgreSQL**
(`pg_current_snapshot()`), qui dit exactement quelles transactions etaient
validees au moment de la lecture. `GET /sync/changes` rend ce qui a ete
valide depuis, sans trou (`app/services/synchro.py`). Il lui faut la
transaction de chaque ligne du journal : colonne `xid`, remplie par defaut.

Le journal ignorait aussi des tables que la tablette relit :

- `expenses` porte `change_seq` mais n'a jamais eu son declencheur ;
- les liaisons `user_roles`, `user_outlets`, `role_permissions` et la table
  `permissions` n'ont pas d'`id` propre (ou pas de `change_seq`) : elles
  sont notees au nom de leur parent. Un role qui change de droits apparait
  comme une modification de `roles`, un agent rattache a un point de vente
  comme une modification de `users`.

Revision ID: 0031_journal_par_transaction
Revises: 0030_reinitialisation_code
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0031_journal_par_transaction"
down_revision: Union[str, None] = "0030_reinitialisation_code"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# (table, parent note dans le journal, colonne qui designe le parent)
LIAISONS = [
    ("user_roles", "users", "user_id"),
    ("user_outlets", "users", "user_id"),
    ("role_permissions", "roles", "role_id"),
    ("permissions", "permissions", "id"),
]

TRACK_RELATED_FUNCTION = """
CREATE OR REPLACE FUNCTION atrium_track_related() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_row jsonb;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_row := to_jsonb(OLD);
    ELSE
        v_row := to_jsonb(NEW);
    END IF;
    -- Toujours UPDATE : c'est le parent qui a change, pas une ligne
    -- que la tablette connaitrait sous son propre nom.
    INSERT INTO sync_change_log (
        id, seq, entity_table, entity_id, op, changed_at, changed_by_device_id
    ) VALUES (
        gen_random_uuid(), nextval('sync_seq'), TG_ARGV[0],
        (v_row->>TG_ARGV[1])::uuid, 'UPDATE', now(), NULL
    );
    RETURN NULL;
END;
$$;
"""


def instructions() -> list[str]:
    """Le SQL de la montee, sans Alembic.

    Les tests construisent leur base avec `create_all`, qui ne pose aucun
    declencheur : ils rejouent ces instructions (et celles de la 0002) pour
    lire le journal comme en production.
    """
    sql = [
        # Sans defaut d'abord : un defaut volatil a l'ajout reecrirait les
        # lignes existantes avec la transaction de cette migration.
        "ALTER TABLE sync_change_log ADD COLUMN IF NOT EXISTS xid xid8",
        "ALTER TABLE sync_change_log ALTER COLUMN xid SET DEFAULT pg_current_xact_id()",
        "CREATE INDEX IF NOT EXISTS ix_sync_change_log_xid ON sync_change_log (xid)",
        "DROP TRIGGER IF EXISTS trg_expenses_sync ON expenses",
        """
        CREATE TRIGGER trg_expenses_sync
        BEFORE INSERT OR UPDATE ON expenses
        FOR EACH ROW EXECUTE FUNCTION atrium_track_change()
        """,
        "DROP TRIGGER IF EXISTS trg_expenses_sync_del ON expenses",
        """
        CREATE TRIGGER trg_expenses_sync_del
        AFTER DELETE ON expenses
        FOR EACH ROW EXECUTE FUNCTION atrium_track_change()
        """,
        TRACK_RELATED_FUNCTION,
    ]
    for table, parent, colonne in LIAISONS:
        sql.append(f"DROP TRIGGER IF EXISTS trg_{table}_sync ON {table}")
        sql.append(
            f"""
            CREATE TRIGGER trg_{table}_sync
            AFTER INSERT OR UPDATE OR DELETE ON {table}
            FOR EACH ROW EXECUTE FUNCTION atrium_track_related('{parent}', '{colonne}')
            """
        )
    return sql


def upgrade() -> None:
    for instruction in instructions():
        op.execute(instruction)


def downgrade() -> None:
    for table, _, _ in LIAISONS:
        op.execute(f"DROP TRIGGER IF EXISTS trg_{table}_sync ON {table}")
    op.execute("DROP FUNCTION IF EXISTS atrium_track_related()")
    op.execute("DROP TRIGGER IF EXISTS trg_expenses_sync ON expenses")
    op.execute("DROP TRIGGER IF EXISTS trg_expenses_sync_del ON expenses")
    op.execute("DROP INDEX IF EXISTS ix_sync_change_log_xid")
    op.execute("ALTER TABLE sync_change_log DROP COLUMN IF EXISTS xid")
