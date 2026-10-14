"""Schemas Pydantic pour les reservations (F1.1-F1.3 du cahier des charges)."""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

from app.models.enums import PaymentMethod, ReservationSource, ReservationStatus, StayUnit
from app.schemas.guests import GuestIn


class ReservationRoomIn(BaseModel):
    id: uuid.UUID | None = Field(default=None, description="UUID v7 genere par la tablette ; absent = genere par le serveur")
    room_type_id: uuid.UUID
    arrival_date: dt.date
    departure_date: dt.date
    adults: int = Field(default=1, ge=1)
    children: int = Field(default=0, ge=0)
    nightly_rate: int | None = Field(
        default=None, ge=0, description="FCFA ; par defaut, le tarif de base du type de chambre"
    )

    @model_validator(mode="after")
    def _check_dates(self) -> "ReservationRoomIn":
        if self.departure_date <= self.arrival_date:
            raise ValueError("La date de depart doit etre posterieure a la date d'arrivee.")
        return self


class ReservationIn(BaseModel):
    id: uuid.UUID | None = Field(default=None, description="UUID v7 genere par la tablette ; absent = genere par le serveur")
    guest_id: uuid.UUID
    source: ReservationSource = ReservationSource.DIRECT
    adults: int = Field(default=1, ge=1)
    children: int = Field(default=0, ge=0)
    special_requests: str | None = None
    internal_notes: str | None = None
    deposit_amount: int | None = Field(
        default=None,
        ge=0,
        description=(
            "Arrhes encaissees maintenant, FCFA (exige deposit_method) ; "
            "absent = montant du par la regle `reservation.deposit_rule`, rien d'encaisse"
        ),
    )
    deposit_method: PaymentMethod | None = Field(
        default=None,
        description="Moyen de paiement des arrhes : seules les especes entrent dans le tiroir",
    )
    deposit_reference: str | None = Field(
        default=None, max_length=80, description="Reference Mobile Money, virement, carte"
    )
    rooms: list[ReservationRoomIn] = Field(min_length=1)

    @model_validator(mode="after")
    def _distinct_ids(self) -> "ReservationIn":
        ids = [line.id for line in self.rooms if line.id is not None]
        if self.id is not None:
            ids.append(self.id)
        if len(ids) != len(set(ids)):
            raise ValueError("Identifiants en double dans la reservation.")
        # Des arrhes encaissees sans moyen de paiement ne peuvent pas etre
        # rapprochees : un virement ne passe pas par le tiroir, des especes si.
        if self.deposit_amount and self.deposit_method is None:
            raise ValueError("deposit_method est obligatoire quand des arrhes sont encaissees.")
        return self


class ReservationRoomOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    room_type_id: uuid.UUID
    room_id: uuid.UUID | None
    arrival_date: dt.date
    departure_date: dt.date
    adults: int
    children: int
    nightly_rate: int
    status: ReservationStatus
    checked_in_at: dt.datetime | None
    checked_out_at: dt.datetime | None
    key_card_code: str | None
    # Surclassement : la categorie reservee a l'origine (`room_type_id` est
    # celle de la chambre occupee), le motif et qui l'a decide. Nuls sinon.
    booked_room_type_id: uuid.UUID | None = None
    upgrade_reason: str | None = None
    upgraded_by: uuid.UUID | None = None
    # Arrivee directe (sans reservation), en nuits ou en heures. Pour un
    # sejour en heures, `departure_date` n'est que la borne exigee par le
    # schema : l'heure de depart est `departure_at`, instant UTC.
    is_walk_in: bool = False
    stay_unit: StayUnit = StayUnit.NIGHTS
    departure_at: dt.datetime | None = None
    rate_set_by: uuid.UUID | None = None


class ReservationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    reference: str
    guest_id: uuid.UUID
    source: ReservationSource
    status: ReservationStatus
    arrival_date: dt.date
    departure_date: dt.date
    adults: int
    children: int
    estimated_total: int
    deposit_amount: int
    deposit_paid_at: dt.datetime | None
    special_requests: str | None
    internal_notes: str | None
    cancelled_at: dt.datetime | None
    cancel_reason: str | None
    rooms: list[ReservationRoomOut]


class AvailabilityOut(BaseModel):
    room_type_id: uuid.UUID
    arrival_date: dt.date
    departure_date: dt.date
    total_rooms: int
    booked_rooms: int
    available_rooms: int


class UpgradeIn(BaseModel):
    """Surclassement : installer le client dans une chambre d'une autre

    categorie que celle reservee. Sans lui, une chambre d'une autre categorie
    reste refusee : un surclassement se decide, il ne se glisse pas.
    """

    keep_rate: bool = Field(
        default=True,
        description="Vrai : surclassement offert, le tarif reserve est garde. "
        "Faux : le tarif par defaut de la nouvelle categorie s'applique",
    )
    reason: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=255)
    ] = Field(description="Le motif, garde sur la ligne")


class CheckInIn(BaseModel):
    room_id: uuid.UUID | None = Field(
        default=None, description="Obligatoire si aucune chambre n'a encore ete assignee"
    )
    folio_id: uuid.UUID | None = Field(
        default=None, description="Id du folio ouvert par la tablette ; absent = genere"
    )
    key_card_code: str | None = None
    upgrade: UpgradeIn | None = Field(
        default=None,
        description="Obligatoire quand la chambre n'est pas de la categorie reservee",
    )


class CheckInOut(ReservationOut):
    """Le dossier, plus l'ardoise **retenue** pour la ligne arrivee.

    Elle peut differer de celle que la tablette proposait : si le sejour etait
    deja arrive (autre tablette, renvoi), le serveur garde la sienne. La
    tablette doit alors adopter celle-ci, faute de quoi tout ce qu'elle
    porterait sur la sienne serait refuse en 404 et bloquerait sa file.
    """

    folio_id: uuid.UUID | None = None


class ChangeRoomIn(BaseModel):
    room_id: uuid.UUID = Field(description="La chambre ou le client s'installe desormais")
    upgrade: UpgradeIn | None = Field(
        default=None,
        description="Obligatoire quand la chambre n'est pas de la categorie du sejour",
    )


class CancelIn(BaseModel):
    reason: str | None = None
    folio_id: uuid.UUID | None = Field(
        default=None,
        description="Id de l'ardoise d'indemnite ouverte par la tablette si des arrhes "
        "sont conservees ; absent = genere",
    )


class PendingDepositsOut(BaseModel):
    """Arrhes encaissees et encore rattachees a une reservation.

    Ni sur une ardoise, ni reconnues : l'argent que l'hotel detient pour des
    clients pas encore arrives.
    """

    count: int
    total: int


class ReservationRoomUpdate(BaseModel):
    """Modification d'une ligne (F1.1). Seuls les champs envoyes changent."""

    id: uuid.UUID
    room_type_id: uuid.UUID | None = None
    arrival_date: dt.date | None = None
    departure_date: dt.date | None = None
    adults: int | None = Field(default=None, ge=1)
    children: int | None = Field(default=None, ge=0)
    nightly_rate: int | None = Field(
        default=None, ge=0, description="FCFA ; sur changement de type, tarif du nouveau type"
    )


class ReservationUpdate(BaseModel):
    """PATCH /reservations/{id} : entete du dossier et/ou lignes a modifier."""

    adults: int | None = Field(default=None, ge=1)
    children: int | None = Field(default=None, ge=0)
    special_requests: str | None = None
    internal_notes: str | None = None
    rooms: list[ReservationRoomUpdate] = Field(default_factory=list)


class CalendarCell(BaseModel):
    """Une chambre un jour donne ; champs de sejour a null si la chambre est libre."""

    room_id: uuid.UUID
    room_number: str
    date: dt.date
    reservation_room_id: uuid.UUID | None = None
    reservation_id: uuid.UUID | None = None
    reference: str | None = None
    guest_name: str | None = None
    status: ReservationStatus | None = None


class CalendarUnassigned(BaseModel):
    """Ligne de reservation sans chambre physique : placee par type, pas par numero."""

    reservation_room_id: uuid.UUID
    reservation_id: uuid.UUID
    reference: str
    guest_name: str
    room_type_id: uuid.UUID
    arrival_date: dt.date
    departure_date: dt.date
    status: ReservationStatus


class CalendarOut(BaseModel):
    date_from: dt.date
    date_to: dt.date
    rows: list[CalendarCell]
    unassigned: list[CalendarUnassigned]


class WalkInStayIn(BaseModel):
    """Arrivee directe : un voyageur sans reservation prend une chambre.

    Une seule requete pour le client, la chambre, la duree, le prix et
    l'arrivee. Les identifiants viennent de la tablette, qui enregistre le
    sejour hors ligne : le meme envoi rejoue retrouve le meme sejour.
    """

    id: uuid.UUID = Field(description="L'id du dossier, genere par la tablette")
    line_id: uuid.UUID | None = Field(
        default=None, description="L'id de la ligne de sejour ; absent = genere"
    )
    folio_id: uuid.UUID | None = Field(
        default=None, description="L'id de l'ardoise ; absent = genere"
    )
    charge_id: uuid.UUID | None = Field(
        default=None, description="L'id de la charge du sejour ; absent = genere"
    )
    guest_id: uuid.UUID | None = Field(default=None, description="Un client deja connu")
    guest: GuestIn | None = Field(
        default=None, description="Ou la fiche a creer (avec son id, pour le rejeu)"
    )
    room_id: uuid.UUID
    unit: StayUnit
    duration: int = Field(ge=1, description="Nombre de nuits, ou d'heures")
    price: int = Field(ge=0, description="FCFA, le prix du sejour entier, saisi librement")
    override_by: uuid.UUID | None = Field(
        default=None,
        description="Responsable (folio.override_limit) qui autorise le depassement du seuil",
    )

    @model_validator(mode="after")
    def _coherent(self) -> "WalkInStayIn":
        if (self.guest_id is None) == (self.guest is None):
            raise ValueError("Donner guest_id ou guest, l'un des deux.")
        # Au-dela d'une journee, ce n'est plus un sejour en heures : c'est
        # une nuit, et elle se compte comme telle.
        if self.unit == StayUnit.HOURS and self.duration > 24:
            raise ValueError("Un sejour en heures ne depasse pas 24 heures.")
        if self.unit == StayUnit.NIGHTS and self.duration > 365:
            raise ValueError("Un sejour ne depasse pas 365 nuits.")
        ids = [i for i in (self.id, self.line_id, self.folio_id, self.charge_id) if i is not None]
        if len(ids) != len(set(ids)):
            raise ValueError("Identifiants en double dans l'arrivee directe.")
        return self
