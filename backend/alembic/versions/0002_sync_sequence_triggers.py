"""sequence et triggers de synchronisation

Met en place le mecanisme decrit au paragraphe 0.3 de
docs/01-modele-de-donnees.md : une sequence globale unique alimente la colonne
`change_seq` de chaque table repliquee et le journal `sync_change_log`, ce qui
donne un ordre total sur toutes les modifications de la base.

Sans cela, une tablette devrait demander "ce qui a change depuis telle heure",
ce qui est faux en pratique : les horloges des terminaux derivent, et deux
transactions concurrentes committent dans un ordre different de celui ou elles
ont ecrit. Une ligne modifiee avant un pull mais commitee juste apres serait
alors perdue definitivement.

Prerequis : PostgreSQL 13 ou superieur, pour `gen_random_uuid()` en natif.

Revision ID: 0002_sync_triggers
Revises: 0001_initial
Create Date: 2026-09-15
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0002_sync_triggers"
down_revision: Union[str, None] = "0001_initial"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# Tables portant une colonne `change_seq`, donc repliquees vers les tablettes.
# Liste explicite plutot qu'une introspection a l'execution : une migration
# doit produire le meme resultat aujourd'hui et dans deux ans.
SYNCED_TABLES = [
    "amenity_consumptions",
    "attachments",
    "business_days",
    "cash_sessions",
    "companies",
    "devices",
    "document_templates",
    "document_types",
    "equipments",
    "floors",
    "folio_items",
    "folios",
    "guest_documents",
    "guests",
    "hotels",
    "housekeeping_task_items",
    "housekeeping_tasks",
    "inventories",
    "inventory_lines",
    "invoice_lines",
    "invoices",
    "maintenance_interventions",
    "maintenance_tickets",
    "menu_categories",
    "menu_item_options",
    "menu_items",
    "notifications",
    "order_item_options",
    "order_items",
    "orders",
    "outlets",
    "payments",
    "prep_stations",
    "print_jobs",
    "print_routes",
    "printers",
    "product_categories",
    "products",
    "rate_plan_prices",
    "rate_plans",
    "reservation_guests",
    "reservation_rooms",
    "reservations",
    "restaurant_tables",
    "roles",
    "room_types",
    "rooms",
    "settings",
    "signatures",
    "stay_nights",
    "stock_levels",
    "stock_locations",
    "stock_movements",
    "suppliers",
    "taxes",
    "users",
]


TRACK_FUNCTION = """
CREATE OR REPLACE FUNCTION atrium_track_change() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_seq    bigint;
    v_row    jsonb;
    v_device uuid;
BEGIN
    -- Une seule valeur par modification : la ligne et sa trace dans le journal
    -- doivent designer le meme point de l'ordre total.
    v_seq := nextval('sync_seq');

    IF TG_OP = 'DELETE' THEN
        INSERT INTO sync_change_log (
            id, seq, entity_table, entity_id, op, changed_at, changed_by_device_id
        ) VALUES (
            gen_random_uuid(), v_seq, TG_TABLE_NAME, OLD.id, 'DELETE', now(), NULL
        );
        RETURN OLD;
    END IF;

    NEW.change_seq := v_seq;

    -- Passage par jsonb : `hotels` n'a pas de colonne origin_device_id, et la
    -- fonction doit rester la meme pour toutes les tables.
    v_row := to_jsonb(NEW);
    v_device := NULLIF(v_row->>'origin_device_id', '')::uuid;

    INSERT INTO sync_change_log (
        id, seq, entity_table, entity_id, op, changed_at, changed_by_device_id
    ) VALUES (
        gen_random_uuid(), v_seq, TG_TABLE_NAME, NEW.id,
        CASE WHEN TG_OP = 'INSERT' THEN 'INSERT' ELSE 'UPDATE' END,
        now(), v_device
    );

    RETURN NEW;
END;
$$;
"""


def upgrade() -> None:
    op.execute("CREATE SEQUENCE IF NOT EXISTS sync_seq AS bigint START WITH 1")
    op.execute(TRACK_FUNCTION)

    for table in SYNCED_TABLES:
        # BEFORE sur INSERT/UPDATE : il faut pouvoir affecter NEW.change_seq
        # avant l'ecriture de la ligne.
        op.execute(
            f"""
            CREATE TRIGGER trg_{table}_sync
            BEFORE INSERT OR UPDATE ON {table}
            FOR EACH ROW EXECUTE FUNCTION atrium_track_change()
            """
        )
        # AFTER sur DELETE : la suppression physique reste exceptionnelle (le
        # modele utilise deleted_at), mais une purge administrative doit quand
        # meme se propager aux tablettes.
        op.execute(
            f"""
            CREATE TRIGGER trg_{table}_sync_del
            AFTER DELETE ON {table}
            FOR EACH ROW EXECUTE FUNCTION atrium_track_change()
            """
        )


def downgrade() -> None:
    for table in SYNCED_TABLES:
        op.execute(f"DROP TRIGGER IF EXISTS trg_{table}_sync ON {table}")
        op.execute(f"DROP TRIGGER IF EXISTS trg_{table}_sync_del ON {table}")
    op.execute("DROP FUNCTION IF EXISTS atrium_track_change()")
    op.execute("DROP SEQUENCE IF EXISTS sync_seq")
