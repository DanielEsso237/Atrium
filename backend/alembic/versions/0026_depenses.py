"""Les depenses de l'hotel hors stock, et le droit de les saisir.

Le benefice que la direction veut voir retire des recettes ce que coute ce qui
est vendu et ce qui est utilise -- le stock le sait deja -- et tout ce que
l'hotel paie d'autre : salaires, electricite, eau, loyer, carburant... Rien ne
permettait de le saisir.

- `expenses` : une depense par ligne, datee de sa journee, dans une rubrique.
  Elle nait sur la tablette, porte son id, et s'annule avec un motif au lieu
  de disparaitre ;
- `expense.write` : saisir, corriger, annuler. L'administrateur, la direction
  et le comptable. La lecture reste sous `accounting.read`, avec les marges.

Revision ID: 0026_depenses
Revises: 0025_arrivee_directe
"""

from __future__ import annotations

import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0026_depenses"
down_revision: Union[str, None] = "0025_arrivee_directe"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Le meme identifiant que `app/db/seed.py`.
EXPENSE_WRITE = uuid.UUID("01920000-0000-7000-8000-000000004140")


def upgrade() -> None:
    op.create_table(
        "expenses",
        sa.Column("business_date", sa.Date(), nullable=False),
        sa.Column(
            "category",
            sa.Enum(
                "SALARIES",
                "ELECTRICITY",
                "WATER",
                "RENT",
                "FUEL",
                "REPAIRS",
                "TELECOM",
                "TAXES",
                "MARKETING",
                "BANK_FEES",
                "OTHER",
                name="expense_category",
                native_enum=False,
                length=32,
            ),
            nullable=False,
        ),
        sa.Column("label", sa.String(length=160), nullable=False),
        sa.Column("amount", sa.BigInteger(), nullable=False),
        sa.Column(
            "method",
            sa.Enum(
                "CASH",
                "CARD",
                "TRANSFER",
                "MOBILE_MONEY",
                "CITY_LEDGER",
                "VOUCHER",
                name="payment_method",
                native_enum=False,
                length=32,
            ),
            nullable=True,
        ),
        sa.Column("supplier", sa.String(length=120), nullable=True),
        sa.Column("reference", sa.String(length=80), nullable=True),
        sa.Column("notes", sa.String(length=255), nullable=True),
        sa.Column("recorded_by", sa.Uuid(), nullable=True),
        sa.Column("is_void", sa.Boolean(), nullable=False),
        sa.Column("void_reason", sa.String(length=255), nullable=True),
        sa.Column("voided_by", sa.Uuid(), nullable=True),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.Column("updated_by", sa.Uuid(), nullable=True),
        sa.Column("origin_device_id", sa.Uuid(), nullable=True),
        sa.Column("change_seq", sa.BigInteger(), nullable=True),
        sa.Column("hotel_id", sa.Uuid(), nullable=False),
        sa.CheckConstraint("amount > 0", name=op.f("ck_expenses_amount_positive")),
        sa.ForeignKeyConstraint(
            ["created_by"],
            ["users.id"],
            name=op.f("fk_expenses_created_by"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["hotel_id"],
            ["hotels.id"],
            name=op.f("fk_expenses_hotel_id"),
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["recorded_by"],
            ["users.id"],
            name=op.f("fk_expenses_recorded_by"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["updated_by"],
            ["users.id"],
            name=op.f("fk_expenses_updated_by"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["voided_by"],
            ["users.id"],
            name=op.f("fk_expenses_voided_by"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_expenses")),
    )
    op.create_index(
        "ix_expenses_business_date", "expenses", ["business_date"], unique=False
    )
    op.create_index(
        op.f("ix_expenses_change_seq"), "expenses", ["change_seq"], unique=False
    )
    op.create_index(
        op.f("ix_expenses_deleted_at"), "expenses", ["deleted_at"], unique=False
    )
    op.create_index(
        op.f("ix_expenses_hotel_id"), "expenses", ["hotel_id"], unique=False
    )
    op.create_index(
        op.f("ix_expenses_origin_device_id"),
        "expenses",
        ["origin_device_id"],
        unique=False,
    )

    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            INSERT INTO permissions (id, code, label, module)
            VALUES (:id, 'expense.write',
                    'Saisir et annuler les depenses de l''hotel', 'accounting')
            ON CONFLICT (code) DO NOTHING
            """
        ),
        {"id": EXPENSE_WRITE},
    )
    for role in ("ADMIN", "MANAGER", "COMPTABLE"):
        bind.execute(
            sa.text(
                """
                INSERT INTO role_permissions (role_id, permission_id)
                SELECT r.id, p.id FROM roles r, permissions p
                 WHERE r.code = :role AND p.code = 'expense.write'
                   AND NOT EXISTS (
                         SELECT 1 FROM role_permissions rp
                          WHERE rp.role_id = r.id AND rp.permission_id = p.id)
                """
            ),
            {"role": role},
        )


def downgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            """
            DELETE FROM role_permissions
             WHERE permission_id IN (SELECT id FROM permissions WHERE code = 'expense.write')
            """
        )
    )
    bind.execute(sa.text("DELETE FROM permissions WHERE code = 'expense.write'"))
    op.drop_index(op.f("ix_expenses_origin_device_id"), table_name="expenses")
    op.drop_index(op.f("ix_expenses_hotel_id"), table_name="expenses")
    op.drop_index(op.f("ix_expenses_deleted_at"), table_name="expenses")
    op.drop_index(op.f("ix_expenses_change_seq"), table_name="expenses")
    op.drop_index("ix_expenses_business_date", table_name="expenses")
    op.drop_table("expenses")
