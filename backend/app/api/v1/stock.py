"""Routes referentiel produits/stocks (fournisseurs, categories, produits, magasins)."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import Product, ProductCategory, StockLocation, Supplier, User
from app.schemas.stock import (
    ProductCategoryIn,
    ProductCategoryOut,
    ProductIn,
    ProductOut,
    StockLocationIn,
    StockLocationOut,
    SupplierIn,
    SupplierOut,
)

router = APIRouter(tags=["stock"])


async def _get_scoped(session: AsyncSession, model, obj_id: uuid.UUID, user: User):
    obj = await session.get(model, obj_id)
    if obj is None or obj.hotel_id != user.hotel_id or obj.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"{model.__name__} introuvable.")
    return obj


# --- Fournisseurs ------------------------------------------------------------


@router.get(
    "/suppliers",
    response_model=list[SupplierOut],
)
async def list_suppliers(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.read")),
) -> list[Supplier]:
    result = await session.execute(
        select(Supplier)
        .where(
            Supplier.hotel_id == user.hotel_id,
            Supplier.deleted_at.is_(None),
        )
        .order_by(Supplier.name)
    )
    return list(result.scalars().all())


@router.post("/suppliers", response_model=SupplierOut, status_code=status.HTTP_201_CREATED)
async def create_supplier(
    payload: SupplierIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.write")),
) -> Supplier:
    supplier = Supplier(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(supplier)
    await session.commit()
    await session.refresh(supplier)
    return supplier


@router.patch("/suppliers/{supplier_id}", response_model=SupplierOut)
async def update_supplier(
    supplier_id: uuid.UUID,
    payload: SupplierIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.write")),
) -> Supplier:
    supplier = await _get_scoped(session, Supplier, supplier_id, user)
    for field, value in payload.model_dump().items():
        setattr(supplier, field, value)
    await session.commit()
    await session.refresh(supplier)
    return supplier


# --- Categories de produits ---------------------------------------------------


@router.get(
    "/product-categories",
    response_model=list[ProductCategoryOut],
)
async def list_product_categories(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.read")),
) -> list[ProductCategory]:
    result = await session.execute(
        select(ProductCategory)
        .where(
            ProductCategory.hotel_id == user.hotel_id,
            ProductCategory.deleted_at.is_(None),
        )
        .order_by(ProductCategory.sort_order, ProductCategory.label)
    )
    return list(result.scalars().all())


@router.post(
    "/product-categories",
    response_model=ProductCategoryOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_product_category(
    payload: ProductCategoryIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.write")),
) -> ProductCategory:
    category = ProductCategory(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(category)
    await session.commit()
    await session.refresh(category)
    return category


@router.patch("/product-categories/{category_id}", response_model=ProductCategoryOut)
async def update_product_category(
    category_id: uuid.UUID,
    payload: ProductCategoryIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.write")),
) -> ProductCategory:
    category = await _get_scoped(session, ProductCategory, category_id, user)
    for field, value in payload.model_dump().items():
        setattr(category, field, value)
    await session.commit()
    await session.refresh(category)
    return category


# --- Produits ------------------------------------------------------------------


@router.get(
    "/products",
    response_model=list[ProductOut],
)
async def list_products(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.read")),
) -> list[Product]:
    result = await session.execute(
        select(Product)
        .where(
            Product.hotel_id == user.hotel_id,
            Product.deleted_at.is_(None),
        )
        .order_by(Product.label)
    )
    return list(result.scalars().all())


@router.post("/products", response_model=ProductOut, status_code=status.HTTP_201_CREATED)
async def create_product(
    payload: ProductIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.write")),
) -> Product:
    product = Product(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(product)
    await session.commit()
    await session.refresh(product)
    return product


@router.patch("/products/{product_id}", response_model=ProductOut)
async def update_product(
    product_id: uuid.UUID,
    payload: ProductIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.write")),
) -> Product:
    """Revalorisation d'un article : `purchase_price`/`sale_price` passent

    par ce meme endpoint, pas par un ecran separe -- le prix est un attribut
    du produit comme un autre, pas un sous-systeme a part.
    """
    product = await _get_scoped(session, Product, product_id, user)
    for field, value in payload.model_dump().items():
        setattr(product, field, value)
    await session.commit()
    await session.refresh(product)
    return product


# --- Magasins / emplacements de stock ------------------------------------------


@router.get(
    "/stock-locations",
    response_model=list[StockLocationOut],
)
async def list_stock_locations(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.read")),
) -> list[StockLocation]:
    result = await session.execute(
        select(StockLocation)
        .where(
            StockLocation.hotel_id == user.hotel_id,
            StockLocation.deleted_at.is_(None),
        )
        .order_by(StockLocation.sort_order, StockLocation.label)
    )
    return list(result.scalars().all())

@router.post(
    "/stock-locations",
    response_model=StockLocationOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_stock_location(
    payload: StockLocationIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.write")),
) -> StockLocation:
    location = StockLocation(hotel_id=user.hotel_id, **payload.model_dump())
    session.add(location)
    await session.commit()
    await session.refresh(location)
    return location


@router.patch("/stock-locations/{location_id}", response_model=StockLocationOut)
async def update_stock_location(
    location_id: uuid.UUID,
    payload: StockLocationIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.write")),
) -> StockLocation:
    location = await _get_scoped(session, StockLocation, location_id, user)
    for field, value in payload.model_dump().items():
        setattr(location, field, value)
    await session.commit()
    await session.refresh(location)
    return location
