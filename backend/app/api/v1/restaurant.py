"""Routes referentiel restauration : points de vente, postes, tables, menu (F3)."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.core.ids import uuid7
from app.db.session import get_session
from app.models import MenuCategory, MenuItem, Outlet, PrepStation, Product, RestaurantTable, User
from app.schemas.restaurant import (
    MenuCategoryIn,
    MenuCategoryOut,
    MenuItemIn,
    MenuItemOut,
    OutletIn,
    OutletOut,
    OutletUpdate,
    PrepStationIn,
    PrepStationOut,
    RestaurantTableIn,
    RestaurantTableOut,
)
from app.services.outlets import PROTECTED_OUTLET_CODES, allowed_outlet_ids
from app.services.stock_locations import ensure_outlet_location

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
    """Les points de vente de l'agent, tous s'il n'est rattache a aucun."""
    stmt = select(Outlet).where(
        Outlet.hotel_id == user.hotel_id,
        Outlet.deleted_at.is_(None),
    )
    allowed = await allowed_outlet_ids(session, user)
    if allowed is not None:
        stmt = stmt.where(Outlet.id.in_(allowed))
    result = await session.execute(stmt.order_by(Outlet.sort_order, Outlet.label))
    return list(result.scalars().all())


async def _code_pris(
    session: AsyncSession, hotel_id: uuid.UUID, code: str, sauf: uuid.UUID | None
) -> bool:
    stmt = select(Outlet.id).where(Outlet.hotel_id == hotel_id, Outlet.code == code)
    if sauf is not None:
        stmt = stmt.where(Outlet.id != sauf)
    return await session.scalar(stmt) is not None


@router.post("/outlets", response_model=OutletOut, status_code=status.HTTP_201_CREATED)
async def create_outlet(
    payload: OutletIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> Outlet:
    """Cree un point de vente ; un renvoi du meme `id` repond 200 sans rien creer."""
    if payload.id is not None:
        existing = await session.get(Outlet, payload.id)
        if existing is not None:
            if existing.hotel_id != user.hotel_id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Point de vente introuvable.")
            response.status_code = status.HTTP_200_OK
            return existing
    # Le code est unique par hotel : le dire plutot que laisser la base lever
    # une erreur 500 que personne ne saurait lire.
    if await _code_pris(session, user.hotel_id, payload.code, None):
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce code de point de vente existe deja.")
    fields = payload.model_dump(exclude={"id"})
    outlet = Outlet(id=payload.id or uuid7(), hotel_id=user.hotel_id, **fields)
    session.add(outlet)
    await session.flush()
    # Son stock, dans la meme transaction : une vente doit avoir ou sortir.
    await ensure_outlet_location(session, outlet)
    await session.commit()
    await session.refresh(outlet)
    return outlet


@router.patch("/outlets/{outlet_id}", response_model=OutletOut)
async def update_outlet(
    outlet_id: uuid.UUID,
    payload: OutletUpdate,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> Outlet:
    """Modifie ou desactive un point de vente -- jamais de suppression."""
    outlet = await session.get(Outlet, outlet_id)
    if outlet is None or outlet.hotel_id != user.hotel_id or outlet.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Point de vente introuvable.")
    fields = payload.model_dump(exclude_unset=True)
    # `null` n'efface que les horaires ; ailleurs il ne veut rien dire.
    fields = {k: v for k, v in fields.items() if v is not None or k in ("opens_at", "closes_at")}
    # Les points de vente d'office (restaurant, reception) sont ceux que la
    # carte, la caisse centrale et les tablettes retrouvent par leur code :
    # les desactiver ou les renommer casserait tout ce qui s'y rattache. Le
    # libelle, lui, reste libre.
    if outlet.code in PROTECTED_OUTLET_CODES:
        if fields.get("is_active") is False:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                "Le point de vente par defaut ne peut pas etre desactive.",
            )
        if "code" in fields and fields["code"] != outlet.code:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                "Le code du point de vente par defaut ne peut pas etre modifie.",
            )
    if "code" in fields and await _code_pris(session, user.hotel_id, fields["code"], outlet.id):
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce code de point de vente existe deja.")
    for field, value in fields.items():
        setattr(outlet, field, value)
    # Le magasin porte le nom du point de vente : renomme, il suit.
    if "label" in fields:
        location = await ensure_outlet_location(session, outlet)
        location.label = outlet.label
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
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> MenuCategory:
    """Cree une categorie ; un renvoi du meme `id` repond 200 sans rien creer."""
    if payload.id is not None:
        existing = await session.get(MenuCategory, payload.id)
        if existing is not None:
            if existing.hotel_id != user.hotel_id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Categorie introuvable.")
            response.status_code = status.HTTP_200_OK
            return existing
    category = MenuCategory(
        id=payload.id or uuid7(), hotel_id=user.hotel_id, **payload.model_dump(exclude={"id"})
    )
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


async def _verifier_produit(session: AsyncSession, product_id: uuid.UUID | None, user: User) -> None:
    """Le produit relie a un article doit etre un produit de cet hotel."""
    if product_id is None:
        return
    produit = await session.get(Product, product_id)
    if produit is None or produit.hotel_id != user.hotel_id or produit.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Produit introuvable.")


@router.post("/menu-items", response_model=MenuItemOut, status_code=status.HTTP_201_CREATED)
async def create_menu_item(
    payload: MenuItemIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("restaurant.write")),
) -> MenuItem:
    """Cree un article ; un renvoi du meme `id` repond 200 sans rien creer."""
    if payload.id is not None:
        existing = await session.get(MenuItem, payload.id)
        if existing is not None:
            if existing.hotel_id != user.hotel_id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Article introuvable.")
            response.status_code = status.HTTP_200_OK
            return existing
    await _verifier_produit(session, payload.product_id, user)
    item = MenuItem(
        id=payload.id or uuid7(), hotel_id=user.hotel_id, **payload.model_dump(exclude={"id"})
    )
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
    await _verifier_produit(session, payload.product_id, user)
    for field, value in payload.model_dump(exclude={"id"}).items():
        setattr(item, field, value)
    await session.commit()
    await session.refresh(item)
    return item
