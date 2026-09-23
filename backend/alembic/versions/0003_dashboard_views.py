"""vues statistiques du dashboard

Trois vues prevues par docs/01-modele-de-donnees.md, paragraphe 11, mais
jamais ecrites : le dashboard direction (cahier des charges, paragraphe 5.1)
a besoin d'agregats (occupation, CA du jour, plan des chambres), pas de
requetes ad-hoc repetees dans chaque endpoint qui en a besoin.

Ce sont des vues simples (pas materialisees) : elles interrogent les tables
en direct a chaque appel. Pour 18 chambres et quelques centaines de lignes de
folio par jour, l'aggregat est instantane -- une vue materialisee ne se
justifierait qu'avec un volume bien plus grand, et ajouterait un probleme de
rafraichissement qu'on n'a pas besoin de resoudre maintenant.

Revision ID: 0003_dashboard_views
Revises: 0002_sync_triggers
Create Date: 2026-09-21
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0003_dashboard_views"
down_revision: Union[str, None] = "0002_sync_triggers"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Plan des chambres avec libelles deja resolus (type, etage) : evite de
    # refaire les memes jointures dans chaque outil de reporting externe qui
    # se branchera un jour directement sur la base.
    op.execute(
        """
        CREATE VIEW v_room_status AS
        SELECT
            r.id,
            r.hotel_id,
            r.number,
            r.occupancy_status,
            r.housekeeping_status,
            r.is_out_of_order,
            rt.code  AS room_type_code,
            rt.label AS room_type_label,
            f.code   AS floor_code,
            f.label  AS floor_label
        FROM rooms r
        JOIN room_types rt ON rt.id = r.room_type_id
        LEFT JOIN floors f ON f.id = r.floor_id
        WHERE r.deleted_at IS NULL AND r.is_active = true
        """
    )

    # Une ligne par hotel : l'occupation est un etat present ("combien de
    # chambres occupees maintenant"), pas une serie historique -- contrairement
    # au chiffre d'affaires ci-dessous, qui lui a un sens jour par jour.
    op.execute(
        """
        CREATE VIEW v_occupancy AS
        SELECT
            hotel_id,
            count(*) AS total_rooms,
            count(*) FILTER (WHERE occupancy_status = 'OCCUPIED') AS occupied_rooms,
            count(*) FILTER (WHERE occupancy_status = 'VACANT')   AS vacant_rooms,
            count(*) FILTER (WHERE is_out_of_order)               AS out_of_order_rooms,
            round(
                100.0 * count(*) FILTER (WHERE occupancy_status = 'OCCUPIED')
                / NULLIF(count(*), 0),
                1
            ) AS occupancy_rate_pct
        FROM rooms
        WHERE deleted_at IS NULL AND is_active = true
        GROUP BY hotel_id
        """
    )

    # Une ligne par (hotel, jour, categorie de charge) : la case "CA JOUR" du
    # dashboard est `SUM(amount) WHERE business_date = aujourd'hui`, le
    # detail par categorie (chambre/restaurant/divers) est deja la pour qui
    # en a besoin sans requete supplementaire.
    op.execute(
        """
        CREATE VIEW v_daily_revenue AS
        SELECT
            f.hotel_id,
            fi.business_date,
            fi.category,
            sum(fi.amount)     AS amount,
            count(*)           AS item_count
        FROM folio_items fi
        JOIN folios f ON f.id = fi.folio_id
        WHERE fi.is_void = false
        GROUP BY f.hotel_id, fi.business_date, fi.category
        """
    )


def downgrade() -> None:
    op.execute("DROP VIEW IF EXISTS v_daily_revenue")
    op.execute("DROP VIEW IF EXISTS v_occupancy")
    op.execute("DROP VIEW IF EXISTS v_room_status")
