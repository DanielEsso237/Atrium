"""Schemas de l'activite des points de vente, telle qu'elle descend a leurs agents."""

from __future__ import annotations

import uuid

from pydantic import BaseModel

from app.models.enums import FolioStatus, FolioType
from app.schemas.billing import FolioItemOut, FolioOut, PaymentOut
from app.schemas.cash_sessions import CashSessionOut


class OutletSaleOut(FolioItemOut):
    """Une ligne vendue par un point de vente, avec l'en-tete de son ardoise.

    L'en-tete seul, sans les autres lignes ni les totaux : l'ardoise d'une
    chambre porte la nuitee et ce que le client a pris ailleurs, que le
    barman n'a pas a voir. Le type suffit a distinguer le paye sur place
    (`WALK_IN`) du porte a la chambre.
    """

    folio_id: uuid.UUID
    folio_number: str
    folio_type: FolioType
    folio_status: FolioStatus


class OutletActivityOut(BaseModel):
    sales: list[OutletSaleOut]
    # Les encaissements passes dans les tiroirs de ces points de vente.
    payments: list[PaymentOut]
    # Les tiroirs de ces points de vente, quel que soit l'agent qui les tient.
    cash_sessions: list[CashSessionOut]
    # Leurs ardoises de comptoir : ouvertes, ou closes sur la fenetre. Une
    # ardoise de comptoir ne porte que des lignes de son point de vente : elle
    # descend entiere.
    tabs: list[FolioOut] = []
