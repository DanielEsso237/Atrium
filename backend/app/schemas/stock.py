"""Schemas Pydantic pour le referentiel produits/stocks et leurs mouvements."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import StockMovementType


class SupplierIn(BaseModel):
    code: str = Field(min_length=1, max_length=32)
    name: str = Field(min_length=1, max_length=160)
    contact_name: str | None = None
    phone: str | None = None
    email: str | None = None
    address: str | None = None
    tax_id: str | None = None
    payment_terms_days: int = 0
    notes: str | None = None


class SupplierOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    name: str
    contact_name: str | None
    phone: str | None
    email: str | None
    payment_terms_days: int


class ProductCategoryIn(BaseModel):
    label: str = Field(min_length=1, max_length=80)
    parent_id: uuid.UUID | None = None
    sort_order: int = 0


class ProductCategoryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    label: str
    parent_id: uuid.UUID | None
    sort_order: int


class ProductIn(BaseModel):
    reference: str = Field(min_length=1, max_length=32)
    label: str = Field(min_length=1, max_length=160)
    category_id: uuid.UUID | None = None
    unit: str = Field(default="U", max_length=16)
    barcode: str | None = None
    purchase_price: int = Field(default=0, ge=0, description="FCFA")
    sale_price: int = Field(default=0, ge=0, description="FCFA")
    min_stock: int = Field(default=0, ge=0)
    is_sellable: bool = False
    default_supplier_id: uuid.UUID | None = None
    notes: str | None = None


class ProductOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    reference: str
    label: str
    category_id: uuid.UUID | None
    unit: str
    barcode: str | None
    purchase_price: int
    sale_price: int
    min_stock: int
    is_sellable: bool
    default_supplier_id: uuid.UUID | None


class StockLocationIn(BaseModel):
    code: str = Field(min_length=1, max_length=32)
    label: str = Field(min_length=1, max_length=80)
    manager_id: uuid.UUID | None = None
    sort_order: int = 0


class StockLocationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    label: str
    manager_id: uuid.UUID | None
    sort_order: int


class StockMovementIn(BaseModel):
    """Journal append-only (voir le modele `StockMovement`) : une erreur se

    corrige par un mouvement inverse, jamais par une modification.

    `quantity` est une magnitude positive pour IN/OUT/TRANSFER/LOSS/RETURN ;
    pour ADJUSTMENT c'est un delta signe direct (peut etre negatif).
    """

    product_id: uuid.UUID
    stock_location_id: uuid.UUID
    type: StockMovementType
    quantity: int
    unit_cost: int = Field(default=0, ge=0, description="FCFA")
    reason: str | None = None
    counterpart_location_id: uuid.UUID | None = Field(
        default=None, description="Obligatoire pour TRANSFER"
    )
    supplier_id: uuid.UUID | None = None


class StockMovementOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    product_id: uuid.UUID
    stock_location_id: uuid.UUID
    type: StockMovementType
    quantity: int
    unit_cost: int
    reason: str | None
    counterpart_location_id: uuid.UUID | None
    moved_at: dt.datetime | None
    moved_by: uuid.UUID | None


class StockLevelOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    product_id: uuid.UUID
    stock_location_id: uuid.UUID
    quantity: int
    last_movement_at: dt.datetime | None
