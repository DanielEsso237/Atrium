"""Schemas Pydantic pour l'authentification."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, ConfigDict


class LoginIn(BaseModel):
    """Connexion par identifiant employe + mot de passe (exigence 6.2)."""

    employee_code: str
    password: str


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int


class RoleOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    code: str
    label: str


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    employee_code: str
    first_name: str
    last_name: str
    email: str | None
    is_active: bool
    must_change_password: bool
    roles: list[RoleOut]
