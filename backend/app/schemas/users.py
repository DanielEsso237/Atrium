"""Schemas Pydantic pour la gestion du personnel (exigence 6.2 -- RBAC)."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.auth import RoleOut


class UserIn(BaseModel):
    """Creation d'un membre du personnel (admin)."""

    employee_code: str = Field(min_length=1, max_length=32)
    first_name: str = Field(min_length=1, max_length=80)
    last_name: str = Field(min_length=1, max_length=80)
    email: str | None = None
    phone: str | None = None
    password: str = Field(min_length=8, description="Mot de passe initial (hache avant stockage)")
    role_codes: list[str] = Field(
        default_factory=list, description='Codes des roles a attribuer, ex. ["RECEPTION"]'
    )


class UserUpdate(BaseModel):
    """Mise a jour d'un membre du personnel (admin). Ne touche pas au mot de passe."""

    first_name: str = Field(min_length=1, max_length=80)
    last_name: str = Field(min_length=1, max_length=80)
    email: str | None = None
    phone: str | None = None
    is_active: bool = True
    role_codes: list[str] = Field(default_factory=list)


class PasswordReset(BaseModel):
    new_password: str = Field(min_length=8)


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    employee_code: str
    first_name: str
    last_name: str
    email: str | None
    phone: str | None
    is_active: bool
    must_change_password: bool
    roles: list[RoleOut]
