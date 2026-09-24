"""Routes referentiel restauration : points de vente, postes, tables, menu (F3)."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import MenuCategory, MenuItem, Outlet, PrepStation, RestaurantTable, User
from app.schemas.restaurant import (
    MenuCategoryIn,
    MenuCategoryOut,
    MenuItemIn,
    MenuItemOut,
    OutletIn,
    OutletOut,
    PrepStationIn,
    PrepStationOut,
    RestaurantTableIn,
    RestaurantTableOut,
)

router = APIRouter(tags=["restauration"])


async def _get_scoped(session: AsyncSession, model, obj_id: uuid.UUID, user: User):
    obj = await session.get(model, obj_id)
    if obj is None or obj.hotel_id != user.hotel_id or obj.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"{model.__name__} introuvable.")
    return obj


# --- Points de vente -----------------------------------------------------------


@router.get(
    "/outlets",
    response_model=list[OutletOut],
)
async def list_outlets(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.read")),
) -> list[Outlet]:
    result = await session.execute(
        select(Outlet)
        .where(
            Outlet.hotel_id == user.hotel_id,
            Outlet.deleted_at.is_(None),
        )
        .order_by(Outlet.sort_order, Outlet.label)
    )
    return list(result.scalars().all())


@router.post("/outlets", response_model=OutletOut, status_code=status.HTTP_201_CREATED)
async def create_outlet(
    payload: OutletIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> Outlet:
    outlet = Outlet(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(outlet)
    await session.commit()
    await session.refresh(outlet)
    return outlet


# --- Postes de preparation -------------------------------------------------------


@router.get(
    "/prep-stations",
    response_model=list[PrepStationOut],
)
async def list_prep_stations(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.read")),
) -> list[PrepStation]:
    result = await session.execute(
        select(PrepStation)
        .where(
            PrepStation.hotel_id == user.hotel_id,
            PrepStation.deleted_at.is_(None),
        )
        .order_by(PrepStation.sort_order, PrepStation.label)
    )
    return list(result.scalars().all())


@router.post(
    "/prep-stations", response_model=PrepStationOut, status_code=status.HTTP_201_CREATED
)
async def create_prep_station(
    payload: PrepStationIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> PrepStation:
    station = PrepStation(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(station)
    await session.commit()
    await session.refresh(station)
    return station


# --- Tables ----------------------------------------------------------------------


@router.get(
    "/tables",
    response_model=list[RestaurantTableOut],
)
async def list_tables(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.read")),
) -> list[RestaurantTable]:
    result = await session.execute(
        select(RestaurantTable)
        .where(
            RestaurantTable.hotel_id == user.hotel_id,
            RestaurantTable.deleted_at.is_(None),
        )
        .order_by(RestaurantTable.number)
    )
    return list(result.scalars().all())


@router.post(
    "/tables", response_model=RestaurantTableOut, status_code=status.HTTP_201_CREATED
)
async def create_table(
    payload: RestaurantTableIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> RestaurantTable:
    table = RestaurantTable(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(table)
    await session.commit()
    await session.refresh(table)
    return table


# --- Categories de menu -----------------------------------------------------------


@router.get(
    "/menu-categories",
    response_model=list[MenuCategoryOut],
)
async def list_menu_categories(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.read")),
) -> list[MenuCategory]:
    result = await session.execute(
        select(MenuCategory)
        .where(
            MenuCategory.hotel_id == user.hotel_id,
            MenuCategory.deleted_at.is_(None),
        )
        .order_by(MenuCategory.sort_order, MenuCategory.label)
    )
    return list(result.scalars().all())


@router.post(
    "/menu-categories", response_model=MenuCategoryOut, status_code=status.HTTP_201_CREATED
)
async def create_menu_category(
    payload: MenuCategoryIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> MenuCategory:
    category = MenuCategory(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(category)
    await session.commit()
    await session.refresh(category)
    return category


# --- Articles du menu --------------------------------------------------------------


@router.get(
    "/menu-items",
    response_model=list[MenuItemOut],
)
async def list_menu_items(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.read")),
) -> list[MenuItem]:
    result = await session.execute(
        select(MenuItem)
        .where(
            MenuItem.hotel_id == user.hotel_id,
            MenuItem.deleted_at.is_(None),
        )
        .order_by(MenuItem.sort_order, MenuItem.label)
    )
    return list(result.scalars().all())


@router.post("/menu-items", response_model=MenuItemOut, status_code=status.HTTP_201_CREATED)
async def create_menu_item(
    payload: MenuItemIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> MenuItem:
    item = MenuItem(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(item)
    await session.commit()
    await session.refresh(item)
    return item


@router.patch("/menu-items/{item_id}", response_model=MenuItemOut)
async def update_menu_item(
    item_id: uuid.UUID,
    payload: MenuItemIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> MenuItem:
    """Revalorisation ou rattachement a un autre poste de preparation --

    changer `prep_station_id` ici suffit a rediriger tous les futurs tickets
    de cet article, sans toucher au code (voir R1 dans le modele `MenuItem`).
    """
    item = await _get_scoped(session, MenuItem, item_id, user)
    for field, value in payload.model_dump().items():
        setattr(item, field, value)
    await session.commit()
    await session.refresh(item)
    return item
