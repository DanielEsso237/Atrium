"""Socle SQLAlchemy : Base declarative et mixins de synchronisation.

Toute table metier herite de `SyncBase`, qui apporte les colonnes decrites au
paragraphe 0.2 de docs/01-modele-de-donnees.md. C'est ce contrat uniforme qui
permet d'ecrire un moteur de synchronisation generique, pilote par la liste des
tables, plutot qu'un cas particulier par entite.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Annotated

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    MetaData,
    String,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, declared_attr, mapped_column

from app.core.ids import uuid7

# Convention de nommage explicite : sans elle, Alembic genere des noms de
# contraintes anonymes que l'on ne peut plus cibler dans une migration.
NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)

    type_annotation_map = {
        dict: JSONB,
        dt.datetime: DateTime(timezone=True),
    }


# --- Alias de types reutilisables -------------------------------------------

# Montants : bigint, en francs CFA entiers.
#
# Le franc CFA n'a pas de subdivision en usage : un montant est un nombre
# entier de francs. Pas de `numeric`, pas de decimales, et surtout pas de
# flottant -- un double ne represente pas exactement 0,1 et une addition de
# factures finit par deriver.
#
# Consequence recherchee : la tablette stocke exactement la meme chose, donc
# la synchronisation recopie la valeur sans aucune conversion. Il n'existe
# aucun endroit dans la chaine ou un facteur d'echelle puisse etre oublie.
Money = Annotated[int, mapped_column(BigInteger)]

# Taux et pourcentages : entier en points de base (un centieme de pour cent).
# Une TVA de 18 % vaut 1800, un taux de 18,5 % vaut 1850.
BasisPoints = Annotated[int, mapped_column(Integer)]

Code = Annotated[str, mapped_column(String(32))]
Label = Annotated[str, mapped_column(String(160))]


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


# --- Mixins ------------------------------------------------------------------


class UUIDPrimaryKey:
    """Cle primaire UUID v7 generee cote client."""

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid7)


class Timestamped:
    created_at: Mapped[dt.datetime] = mapped_column(
        default=utcnow, server_default=func.now()
    )
    updated_at: Mapped[dt.datetime] = mapped_column(
        default=utcnow, onupdate=utcnow, server_default=func.now()
    )


class SoftDelete:
    """Suppression logique.

    Une suppression physique est invisible pour une tablette hors ligne : elle
    n'apparait dans aucun delta et la ligne ressusciterait au prochain push.
    Toutes les lectures applicatives filtrent donc `deleted_at IS NULL`.
    """

    deleted_at: Mapped[dt.datetime | None] = mapped_column(default=None, index=True)

    @property
    def is_deleted(self) -> bool:
        return self.deleted_at is not None


class Auditable:
    """Traceurs d'ecriture (exigence 6.2 du cahier des charges)."""

    @declared_attr
    def created_by(cls) -> Mapped[uuid.UUID | None]:
        return mapped_column(ForeignKey("users.id", ondelete="SET NULL"), default=None)

    @declared_attr
    def updated_by(cls) -> Mapped[uuid.UUID | None]:
        return mapped_column(ForeignKey("users.id", ondelete="SET NULL"), default=None)

    # Volontairement sans cle etrangere vers `devices`.
    #
    # Deux raisons. D'abord le mode hors ligne : une tablette peut pousser des
    # ecritures avant que son propre enregistrement ne soit remonte, et une
    # contrainte referentielle rejetterait une synchronisation parfaitement
    # legitime. Ensuite les cycles : `devices` pointe vers `outlets`,
    # `printers` et `roles`, qui portent tous cette colonne -- la contrainte
    # rendrait le graphe des tables non ordonnable.
    #
    # C'est une colonne de provenance, utile au diagnostic terrain et a
    # l'arbitrage des conflits. La piste d'audit reelle, elle, vit dans
    # `audit_logs`, cote serveur.
    @declared_attr
    def origin_device_id(cls) -> Mapped[uuid.UUID | None]:
        return mapped_column(default=None, index=True)


class Syncable:
    """Curseur de replication.

    `change_seq` est alimente par un trigger PostgreSQL depuis une sequence
    globale unique a toute la base. Les tablettes ne retiennent qu'un entier par
    table et demandent `WHERE change_seq > :last_seq ORDER BY change_seq`.

    On n'utilise deliberement pas `updated_at` pour cela : les horloges des
    tablettes derivent, et surtout deux transactions concurrentes committent
    dans un ordre different de celui ou elles ont ecrit -- une ligne ecrite
    avant un pull mais commitee apres serait perdue definitivement.
    """

    @declared_attr
    def change_seq(cls) -> Mapped[int | None]:
        return mapped_column(BigInteger, default=None, index=True)


class HotelScoped:
    """Rattachement a l'etablissement.

    Le projet demarre en mono-etablissement (une seule ligne dans `hotels`),
    mais la colonne est posee des maintenant : l'ajouter apres coup sur une
    soixantaine de tables deja peuplees couterait une migration lourde.
    """

    @declared_attr
    def hotel_id(cls) -> Mapped[uuid.UUID]:
        return mapped_column(
            ForeignKey("hotels.id", ondelete="RESTRICT"), nullable=False, index=True
        )


class SyncBase(UUIDPrimaryKey, Timestamped, SoftDelete, Auditable, Syncable, Base):
    """Table metier repliquee sur les tablettes."""

    __abstract__ = True


class RootBase(UUIDPrimaryKey, Timestamped, SoftDelete, Syncable, Base):
    """Table metier sans colonnes d'audit.

    Reservee a `hotels`, qui est la racine du graphe : lui donner un
    `created_by` vers `users` creerait un cycle avec `users.hotel_id`, alors
    que l'etablissement est cree une seule fois, a l'installation.
    """

    __abstract__ = True


class ServerBase(UUIDPrimaryKey, Timestamped, Base):
    """Table qui reste sur le serveur central (audit, change log, jetons)."""

    __abstract__ = True


class RefBase(SyncBase):
    """Table de referentiel : parametree a l'administration, lue partout."""

    __abstract__ = True

    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default="true"
    )
