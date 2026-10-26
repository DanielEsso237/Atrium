"""Une file d'envoi bloquee se voit d'un autre poste.

Un refus du serveur bloque la file d'une tablette, avec tout ce qui attend
derriere -- et cela ne se voyait que sur la tablette elle-meme. La reception
pouvait travailler une demi-journee sans que rien ne remonte, et personne
d'autre ne le savait.

- `sync_blocks` : la tablette y annonce son blocage hors de sa file (qui est
  justement bloquee), puis le dit leve. Journalisee comme les autres tables,
  pour redescendre vers les autres postes.
- `sync.monitor` : lire ces rapports et la liste des tablettes.
  L'administrateur et la direction.

Revision ID: 0034_file_bloquee_a_distance
Revises: 0033_droit_faire_le_menage
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0034_file_bloquee_a_distance"
down_revision: Union[str, None] = "0033_droit_faire_le_menage"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Le meme identifiant que `app/db/seed.py` et la tablette.
DROIT = uuid.UUID("01920000-0000-7000-8000-000000004148")
CODE = "sync.monitor"
ROLES = ["ADMIN", "MANAGER"]


def declencheurs() -> list[str]:
    """Le journal de `GET /sync/changes`, repris par les tests."""
    return [
        "DROP TRIGGER IF EXISTS trg_sync_blocks_sync ON sync_blocks",
        """
        CREATE TRIGGER trg_sync_blocks_sync
        BEFORE INSERT OR UPDATE ON sync_blocks
        FOR EACH ROW EXECUTE FUNCTION atrium_track_change()
        """,
        "DROP TRIGGER IF EXISTS trg_sync_blocks_sync_del ON sync_blocks",
        """
        CREATE TRIGGER trg_sync_blocks_sync_del
        AFTER DELETE ON sync_blocks
        FOR EACH ROW EXECUTE FUNCTION atrium_track_change()
        """,
    ]


def upgrade() -> None:
    op.create_table(
        "sync_blocks",
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("author_id", sa.Uuid(), nullable=True),
        sa.Column("reported_by", sa.Uuid(), nullable=True),
        sa.Column("entity_table", sa.String(length=64), nullable=False),
        sa.Column("entity_id", sa.Uuid(), nullable=False),
        sa.Column("operation", sa.String(length=8), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=True),
        sa.Column("http_status", sa.Integer(), nullable=True),
        sa.Column("reason", sa.Text(), nullable=True),
        sa.Column("written_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("blocked_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("reported_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("pending_behind", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("resolution", sa.String(length=16), nullable=True),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.Column("updated_by", sa.Uuid(), nullable=True),
        sa.Column("origin_device_id", sa.Uuid(), nullable=True),
        sa.Column("change_seq", sa.BigInteger(), nullable=True),
        sa.Column("hotel_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(["author_id"], ["users.id"], name=op.f("fk_sync_blocks_author_id"), ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], name=op.f("fk_sync_blocks_created_by"), ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["device_id"], ["devices.id"], name=op.f("fk_sync_blocks_device_id"), ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["hotel_id"], ["hotels.id"], name=op.f("fk_sync_blocks_hotel_id"), ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["reported_by"], ["users.id"], name=op.f("fk_sync_blocks_reported_by"), ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["updated_by"], ["users.id"], name=op.f("fk_sync_blocks_updated_by"), ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_sync_blocks")),
    )
    op.create_index(op.f("ix_sync_blocks_change_seq"), "sync_blocks", ["change_seq"], unique=False)
    op.create_index(op.f("ix_sync_blocks_deleted_at"), "sync_blocks", ["deleted_at"], unique=False)
    op.create_index(op.f("ix_sync_blocks_device_id"), "sync_blocks", ["device_id"], unique=False)
    op.create_index(op.f("ix_sync_blocks_hotel_id"), "sync_blocks", ["hotel_id"], unique=False)
    op.create_index(op.f("ix_sync_blocks_origin_device_id"), "sync_blocks", ["origin_device_id"], unique=False)
    op.create_index("ix_sync_blocks_status", "sync_blocks", ["hotel_id", "status"], unique=False)
    for instruction in declencheurs():
        op.execute(instruction)

    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            VALUES (:id, :code, 'Suivre les tablettes et leurs files bloquees', 'sync')
            ON CONFLICT (code) DO NOTHING
            """
        ),
        {"id": DROIT, "code": CODE},
    )
    for role in ROLES:
        bind.execute(
            sa.text(
                """
                INSERT INTO role_permissions (role_id, permission_id)
                SELECT r.id, p.id FROM roles r, permissions p
                 WHERE r.code = :role AND p.code = :code
                   AND NOT EXISTS (
                         SELECT 1 FROM role_permissions rp
                          WHERE rp.role_id = r.id AND rp.permission_id = p.id)
                """
            ),
            {"role": role, "code": CODE},
        )


def downgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            DELETE FROM role_permissions
             WHERE permission_id IN (SELECT id FROM permissions WHERE code = :code)
            """
        ),
        {"code": CODE},
    )
    bind.execute(sa.text("DELETE FROM permissions WHERE code = :code"), {"code": CODE})
    op.execute("DROP TRIGGER IF EXISTS trg_sync_blocks_sync_del ON sync_blocks")
    op.execute("DROP TRIGGER IF EXISTS trg_sync_blocks_sync ON sync_blocks")
    op.drop_table("sync_blocks")
