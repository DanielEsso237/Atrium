"""Schemas des sejours a qui un comptoir peut porter une consommation."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel

from app.models.enums import ReservationStatus
from app.schemas.billing import FolioOut


class ChargeableStayOut(BaseModel):
    """Un sejour en cours et son ardoise ouverte.

    Du client, le nom et le plafond seulement : le barman a besoin de savoir
    a qui il porte, et la tablette de refuser avant le serveur une charge qui
    creverait le plafond. Ni telephone, ni piece d'identite.
    """

    stay_id: uuid.UUID
    reservation_id: uuid.UUID
    reservation_reference: str
    stay_status: ReservationStatus
    arrival_date: dt.date
    departure_date: dt.date
    checked_in_at: dt.datetime | None
    room_id: uuid.UUID
    room_number: str
    room_type_id: uuid.UUID
    room_type_code: str
    room_type_label: str
    guest_id: uuid.UUID
    guest_code: str
    guest_first_name: str
    guest_last_name: str
    guest_credit_limit: int
    # L'ardoise entiere, lignes comprises : sans elles, la tablette
    # recalculerait le solde sur les seules consommations du bar, et le
    # controle du plafond laisserait passer ce que le serveur refuse.
    folio: FolioOut
