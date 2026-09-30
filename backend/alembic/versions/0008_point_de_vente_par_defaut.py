"""un point de vente « Restaurant » par defaut dans chaque hotel

Donnees, pas de schema : chaque hotel existant recoit un point de vente de
code RESTO s'il n'en a pas deja un (actif, desactive ou supprime : la
contrainte d'unicite (hotel_id, code) les compte tous). Un hotel qui a deja
cree le sien a la main n'est pas touche.

Revision ID: 0008_point_de_vente_par_defaut
Revises: 0007_agents_points_de_vente
Create Date: 2026-09-30
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

from app.core.ids import uuid7

revision: str = "0008_point_de_vente_par_defaut"
down_revision: Union[str, None] = "0007_agents_points_de_vente"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

CODE = "RESTO"

# L'hotel de demonstration et son point de vente : les memes identifiants
# que `app/db/seed.py`, pour que le seed retrouve la ligne au lieu d'en creer
# une seconde. Les autres hotels recoivent un identifiant neuf.
DEMO_HOTEL = uuid.UUID("01920000-0000-7000-8000-000000000001")
DEMO_RESTO = uuid.UUID("01920000-0000-7000-8000-000000007001")


def upgrade() -> None:
    bind = op.get_bind()
    hotels = sa.table("hotels", sa.column("id", sa.Uuid()))
    outlets = sa.table(
        "outlets",
        sa.column("id", sa.Uuid()),
        sa.column("hotel_id", sa.Uuid()),
        sa.column("code", sa.String()),
        sa.column("label", sa.String()),
        sa.column("allows_room_charge", sa.Boolean()),
        sa.column("sort_order", sa.Integer()),
    )

    hotel_ids = list(bind.execute(sa.select(hotels.c.id)).scalars())
    deja = set(bind.execute(sa.select(outlets.c.hotel_id).where(outlets.c.code == CODE)).scalars())

    rows = [
        {
            "id": DEMO_RESTO if hotel_id == DEMO_HOTEL else uuid7(),
            "hotel_id": hotel_id,
            "code": CODE,
            "label": "Restaurant",
            "allows_room_charge": True,
            "sort_order": 0,
        }
        for hotel_id in hotel_ids
        if hotel_id not in deja
    ]
    if rows:
        op.bulk_insert(outlets, rows)


def downgrade() -> None:
    # Volontairement vide : le point de vente a pu recevoir des commandes
    # depuis, et un point de vente ne se supprime jamais (voir l'API).
    pass
