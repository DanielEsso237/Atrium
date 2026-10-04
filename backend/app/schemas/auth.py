"""Schemas Pydantic pour l'authentification."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, ConfigDict, field_validator


class LoginIn(BaseModel):
    """Connexion par identifiant employe + mot de passe (exigence 6.2)."""

    employee_code: str
    password: str
    # Tablette enregistree (table `devices`), facultatif : rattache le jeton
    # de rafraichissement a l'appareil pour pouvoir le revoquer seul.
    device_id: uuid.UUID | None = None


class RefreshIn(BaseModel):
    refresh_token: str


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    refresh_token: str
    refresh_expires_in: int


class RoleOut(BaseModel):
    """Un role et ses permissions.

    Les permissions voyagent avec le role : c'est ce qui permet a une tablette
    d'enregistrer, a la connexion en ligne, les droits d'un agent qu'elle ne
    connaissait pas -- les ecrans et le routeur les lisent en local.
    """

    model_config = ConfigDict(from_attributes=True)

    code: str
    label: str
    permissions: list[str] = []

    @field_validator("permissions", mode="before")
    @classmethod
    def _codes(cls, value: object) -> list[str]:
        return sorted(getattr(p, "code", p) for p in (value or []))


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
    # Ses points de vente (vide = tous) : la tablette, partagee, en tire les
    # onglets de l'ecran Commande de l'agent connecte.
    outlet_ids: list[uuid.UUID] = []
