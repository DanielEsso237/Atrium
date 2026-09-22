"""Schemas Pydantic pour le dashboard (cahier des charges, paragraphe 5.1)."""

from __future__ import annotations

import datetime as dt

from pydantic import BaseModel


class OccupancySummary(BaseModel):
    total_rooms: int
    occupied_rooms: int
    vacant_rooms: int
    out_of_order_rooms: int
    occupancy_rate_pct: float | None


class RevenueByCategory(BaseModel):
    category: str
    amount: int


class DashboardSummary(BaseModel):
    business_date: dt.date
    occupancy: OccupancySummary
    active_reservations: int
    arrivals_today: int
    departures_today: int
    today_revenue_total: int
    today_revenue_by_category: list[RevenueByCategory]
    rooms_to_clean: int
