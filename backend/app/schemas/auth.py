"""Schemas Pydantic pour l'authentification."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


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


class AuthorizeIn(BaseModel):
    """Le code d'un responsable, saisi sur la tablette d'un collegue.

    Verifie sans ouvrir de session : le responsable autorise un geste, il ne
    se connecte pas a la place de l'agent.
    """

    employee_code: str
    secret: str
    permission: str


class AuthorizeOut(BaseModel):
    user_id: uuid.UUID
    first_name: str
    last_name: str


class DelegateIn(BaseModel):
    """Le code d'un responsable, pour remonter les ecritures d'un agent
    absent restees sur la tablette."""

    author_id: uuid.UUID
    employee_code: str
    secret: str
    reason: str = Field(min_length=3, max_length=500)
    # L'identifiant stable de la tablette (`sync_statuses.device_id`), pour
    # la trace.
    device_id: uuid.UUID | None = None


class DelegateOut(BaseModel):
    access_token: str
    expires_in: int
    approver: AuthorizeOut


class ResetSecretIn(BaseModel):
    """Un agent a oublie son code ; un responsable valide sur place.

    `approver_secret` part en clair, comme tout secret vers `/auth/login`
    (HTTPS) ; la tablette l'efface de sa file des que le serveur a repondu.
    """

    employee_code: str
    approver_code: str
    approver_secret: str
    new_pin: str | None = Field(default=None, pattern=r"^\d{6}$")
    new_password: str | None = Field(default=None, min_length=8)

    @model_validator(mode="after")
    def _au_moins_un(self) -> "ResetSecretIn":
        if self.new_pin is None and self.new_password is None:
            raise ValueError("Un nouveau PIN, un nouveau mot de passe, ou les deux.")
        return self


class ChangePinIn(BaseModel):
    """Un agent passe de son ancien code a un PIN de 6 chiffres.

    Decision du 25 octobre : le PIN fait 6 chiffres pour tout le monde, et
    l'agent dont le code en a 4 en choisit un nouveau a sa connexion. Sans
    session, comme `ResetSecretIn` : hors ligne, la tablette enfile le geste,
    et c'est l'ancien code, reverifie ici, qui tient lieu de session.
    """

    employee_code: str
    current_secret: str
    new_pin: str = Field(pattern=r"^\d{6}$")


class ChangePinOut(BaseModel):
    user_id: uuid.UUID


class ResetSecretOut(BaseModel):
    user_id: uuid.UUID
    approved_by: uuid.UUID


class CredentialOut(UserOut):
    """Ce qu'il faut a la tablette pour reconnaitre un agent hors ligne.

    La fiche entiere, roles et droits compris, et pas seulement les
    empreintes : la tablette du menage ne lit pas `/users`, et un agent
    reconnu sans ses droits n'ouvrirait aucun ecran.
    """

    pin_hash: str | None
    password_hash: str | None
    failed_login_count: int
    locked_until: dt.datetime | None
