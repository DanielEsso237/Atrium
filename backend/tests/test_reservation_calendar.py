"""Grille du planning (GET /reservations/calendar), sans base."""

from __future__ import annotations

import datetime as dt
import uuid

from app.api.v1.reservations import build_calendar
from app.models.enums import ReservationStatus

D = dt.date
R101, R102 = uuid.uuid4(), uuid.uuid4()
ROOMS = [{"id": R101, "number": "101"}, {"id": R102, "number": "102"}]


def _line(room_id, arrival, departure, status=ReservationStatus.CONFIRMED, ref="RES-000001"):
    return {
        "reservation_room_id": uuid.uuid4(),
        "reservation_id": uuid.uuid4(),
        "room_id": room_id,
        "room_type_id": uuid.uuid4(),
        "arrival_date": arrival,
        "departure_date": departure,
        "status": status,
        "reference": ref,
        "guest_name": "Awa Diallo",
    }


def test_une_ligne_par_chambre_et_par_jour():
    rows, unassigned = build_calendar(ROOMS, [], D(2026, 9, 1), D(2026, 9, 3))
    assert len(rows) == 2 * 3
    assert all(r.reservation_id is None for r in rows)
    assert unassigned == []


def test_la_nuit_du_depart_est_libre():
    line = _line(R101, D(2026, 9, 1), D(2026, 9, 3))
    rows, _ = build_calendar(ROOMS, [line], D(2026, 9, 1), D(2026, 9, 3))
    occupied = {(r.room_number, r.date) for r in rows if r.reference}
    assert occupied == {("101", D(2026, 9, 1)), ("101", D(2026, 9, 2))}


def test_sejour_qui_deborde_la_periode_est_coupe():
    line = _line(R102, D(2026, 8, 25), D(2026, 9, 10))
    rows, _ = build_calendar(ROOMS, [line], D(2026, 9, 1), D(2026, 9, 2))
    assert [r.date for r in rows if r.reference] == [D(2026, 9, 1), D(2026, 9, 2)]


def test_ligne_sans_chambre_part_dans_unassigned():
    line = _line(None, D(2026, 9, 1), D(2026, 9, 2))
    rows, unassigned = build_calendar(ROOMS, [line], D(2026, 9, 1), D(2026, 9, 1))
    assert all(r.reference is None for r in rows)
    assert [u.reservation_room_id for u in unassigned] == [line["reservation_room_id"]]


def test_sejour_en_cours_prime_sur_un_depart_le_meme_jour():
    parti = _line(R101, D(2026, 9, 1), D(2026, 9, 3), ReservationStatus.CHECKED_OUT, "RES-1")
    present = _line(R101, D(2026, 9, 2), D(2026, 9, 4), ReservationStatus.CHECKED_IN, "RES-2")
    for lines in ([parti, present], [present, parti]):
        rows, _ = build_calendar(ROOMS, lines, D(2026, 9, 2), D(2026, 9, 2))
        cell = next(r for r in rows if r.room_id == R101)
        assert cell.reference == "RES-2"
