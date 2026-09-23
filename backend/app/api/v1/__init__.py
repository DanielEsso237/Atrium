"""Assemble les routeurs de la version 1 de l'API."""

from __future__ import annotations

from fastapi import APIRouter

from app.api.v1.auth import router as auth_router
from app.api.v1.billing import router as billing_router
from app.api.v1.dashboard import router as dashboard_router
from app.api.v1.guests import router as guests_router
from app.api.v1.hotel import router as hotel_router
from app.api.v1.housekeeping import router as housekeeping_router
from app.api.v1.maintenance import router as maintenance_router
from app.api.v1.orders import router as orders_router
from app.api.v1.print_jobs import router as print_jobs_router
from app.api.v1.printing import router as printing_router
from app.api.v1.reservations import router as reservations_router
from app.api.v1.restaurant import router as restaurant_router
from app.api.v1.room_types import router as room_types_router
from app.api.v1.rooms import router as rooms_router
from app.api.v1.stock import router as stock_router
from app.api.v1.stock_movements import router as stock_movements_router
from app.api.v1.users import router as users_router

router = APIRouter()
router.include_router(auth_router)
router.include_router(billing_router)
router.include_router(dashboard_router)
router.include_router(guests_router)
router.include_router(hotel_router)
router.include_router(housekeeping_router)
router.include_router(maintenance_router)
router.include_router(orders_router)
router.include_router(print_jobs_router)
router.include_router(printing_router)
router.include_router(reservations_router)
router.include_router(restaurant_router)
router.include_router(room_types_router)
router.include_router(rooms_router)
router.include_router(stock_router)
router.include_router(stock_movements_router)
router.include_router(users_router)
