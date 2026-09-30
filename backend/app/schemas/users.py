"""Schemas Pydantic pour la gestion du personnel (exigence 6.2 -- RBAC)."""

from __future__ import annotations

import uuid

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.schemas.auth import RoleOut


class UserIn(BaseModel):
    """Creation d'un membre du personnel (admin).

    Un PIN ou un mot de passe, au moins l'un des deux : la reception se
    connecte au PIN sur la tablette, l'administration au mot de passe.
    """

    # Cle generee par la tablette : un renvoi du meme id ne cree pas un second
    # agent.
    id: uuid.UUID | None = Field(default=None, description="UUID v7 genere par la tablette")
    employee_code: str = Field(min_length=1, max_length=32)
    first_name: str = Field(min_length=1, max_length=80)
    last_name: str = Field(min_length=1, max_length=80)
    email: str | None = None
    phone: str | None = None
    password: str | None = Field(
        default=None, min_length=8, description="Mot de passe initial (hache avant stockage)"
    )
    pin: str | None = Field(
        default=None, pattern=r"^\d{4,8}$", description="PIN de 4 a 8 chiffres (hache avant stockage)"
    )
    role_codes: list[str] = Field(
        default_factory=list, description='Codes des roles a attribuer, ex. ["RECEPTION"]'
    )
    outlet_ids: list[uuid.UUID] = Field(
        default_factory=list, description="Points de vente de l'agent ; vide = tous"
    )

    @model_validator(mode="after")
    def _un_secret(self) -> UserIn:
        if self.password is None and self.pin is None:
            raise ValueError("Un PIN ou un mot de passe est obligatoire.")
        return self


class UserUpdate(BaseModel):
    """Mise a jour d'un membre du personnel (admin). Ne touche pas au mot de passe."""

    first_name: str = Field(min_length=1, max_length=80)
    last_name: str = Field(min_length=1, max_length=80)
    email: str | None = None
    phone: str | None = None
    is_active: bool = True
    role_codes: list[str] = Field(default_factory=list)
    outlet_ids: list[uuid.UUID] | None = Field(
        default=None,
        description="Remplace les points de vente de l'agent ; absent = inchanges, [] = tous",
    )


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
    outlet_ids: list[uuid.UUID]
