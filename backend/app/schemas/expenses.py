"""Les depenses de l'hotel hors stock (voir `models.billing.Expense`)."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import ExpenseCategory, PaymentMethod

# Au-dela, c'est une faute de frappe (un zero de trop), pas une depense
# d'hotel. La tablette applique la meme borne avant d'enfiler.
MONTANT_MAX = 1_000_000_000


class ExpenseIn(BaseModel):
    """Une depense saisie. L'id vient de la tablette : un renvoi par la file
    rend la depense deja enregistree au lieu d'en creer une seconde."""

    id: uuid.UUID | None = None
    business_date: dt.date
    category: ExpenseCategory
    label: str = Field(min_length=1, max_length=160)
    amount: int = Field(gt=0, le=MONTANT_MAX, description="FCFA")
    method: PaymentMethod | None = None
    supplier: str | None = Field(default=None, max_length=120)
    reference: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=255)


class ExpenseUpdate(BaseModel):
    """La depense corrigee, en entier : la tablette renvoie tout, et un
    renvoi du meme corps ne change rien."""

    business_date: dt.date
    category: ExpenseCategory
    label: str = Field(min_length=1, max_length=160)
    amount: int = Field(gt=0, le=MONTANT_MAX, description="FCFA")
    method: PaymentMethod | None = None
    supplier: str | None = Field(default=None, max_length=120)
    reference: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=255)


class ExpenseVoidIn(BaseModel):
    reason: str = Field(min_length=1, max_length=255)


class ExpenseOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    business_date: dt.date
    category: ExpenseCategory
    label: str
    amount: int
    method: PaymentMethod | None
    supplier: str | None
    reference: str | None
    notes: str | None
    recorded_by: uuid.UUID | None
    is_void: bool
    void_reason: str | None
    voided_by: uuid.UUID | None
    created_at: dt.datetime
    updated_at: dt.datetime
