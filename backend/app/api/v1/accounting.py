"""Marges et valeur du stock : « la compta en gros ».

Trois lectures, aucune ecriture :

- ce qu'une unite de chaque produit rapporte au prix de la carte ;
- ce que chaque point de vente a gagne sur une periode ;
- ce que vaut le stock de chaque magasin.

**Le cout d'une vente est celui du jour de la vente.** La sortie de stock
qu'une ligne vendue declenche garde le cout moyen du moment
(`deduct_for_sale`) : la marge d'une semaine passee ne bouge pas a la
livraison suivante. Les sorties d'avant cette regle n'ont pas de cout ; elles
prennent celui du produit aujourd'hui.

**Ce qui ne sort d'aucun stock n'a pas de cout connu** -- un plat du jour, un
service. Sa recette est comptee, a part (`uncosted_revenue`), et reste hors
de la marge : l'y mettre le donnerait pour gratuit.

Un droit a part, `accounting.read` : le comptoir lit son stock
(`stock.read`) mais compte son tiroir a l'aveugle, et une marge lui donnerait
sa recette.
La valeur du stock s'ouvre aussi a qui tient l'economat
(`stock.manage`) : c'est son stock, et elle ne dit rien d'une recette.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import Date, case, cast, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_any_permission, require_permission
from app.db.session import get_session
from app.models import (
    Folio,
    FolioItem,
    Hotel,
    Outlet,
    Product,
    StockLevel,
    StockLocation,
    StockMovement,
    User,
)
from app.models.enums import StockMovementStatus, StockMovementType
from app.schemas.accounting import (
    DailyCostOut,
    LocationStockValueOut,
    MarginReportOut,
    OutletMarginOut,
    ProductMarginOut,
    SoldProductMarginOut,
    StockValueLineOut,
    StockValueOut,
)
from app.services.business_day import current_business_date
from app.services.costing import margin_rate_bp, unit_cost_of, unit_cost_sql
from app.services.outlets import allowed_outlet_ids

router = APIRouter(prefix="/accounting", tags=["comptabilite"])


@router.get("/product-margins", response_model=list[ProductMarginOut])
async def product_margins(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("accounting.read")),
) -> list[ProductMarginOut]:
    """La marge d'une unite de chaque produit : prix de vente moins cout."""
    produits = await session.scalars(
        select(Product)
        .where(Product.hotel_id == user.hotel_id, Product.deleted_at.is_(None))
        .order_by(Product.label, Product.id)
    )
    marges = []
    for p in produits:
        cout = unit_cost_of(p)
        marges.append(
            ProductMarginOut(
                product_id=p.id,
                reference=p.reference,
                label=p.label,
                purchase_price=p.purchase_price,
                average_cost=p.average_cost,
                unit_cost=cout,
                sale_price=p.sale_price,
                margin=p.sale_price - cout,
                margin_rate_bp=margin_rate_bp(p.sale_price - cout, p.sale_price),
            )
        )
    return marges


@router.get("/margins", response_model=MarginReportOut)
async def margins(
    date_from: dt.date | None = Query(
        default=None, description="Premiere journee hoteliere incluse ; par defaut, six jours avant `date_to`"
    ),
    date_to: dt.date | None = Query(
        default=None, description="Derniere journee hoteliere incluse ; par defaut, la journee en cours"
    ),
    outlet_id: uuid.UUID | None = Query(default=None, description="Un seul point de vente"),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("accounting.read")),
) -> MarginReportOut:
    """La marge de chaque point de vente sur la periode, article par article.

    Sans dates : les sept dernieres journees hotelieres, celle en cours
    comprise. Une ligne annulee ne compte ni en recette ni en cout.
    """
    # Des dates seules, celles de la journee hoteliere : jamais `date.today()`.
    if date_to is None:
        date_to = await current_business_date(session, user.hotel_id)
    if date_from is None:
        date_from = date_to - dt.timedelta(days=6)
    if date_from > date_to:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "date_from est apres date_to."
        )

    # Le meme perimetre que le tableau de bord des points de vente : un agent
    # rattache ne lit que les siens.
    allowed = await allowed_outlet_ids(session, user)
    stmt = select(Outlet).where(Outlet.hotel_id == user.hotel_id)
    if allowed is not None:
        stmt = stmt.where(Outlet.id.in_(allowed))
    if outlet_id is not None:
        stmt = stmt.where(Outlet.id == outlet_id)
    else:
        # Un point de vente desactive garde son histoire quand on le demande,
        # mais n'encombre pas la liste.
        stmt = stmt.where(Outlet.deleted_at.is_(None))
    outlets = list(
        (await session.scalars(stmt.order_by(Outlet.sort_order, Outlet.label, Outlet.id))).all()
    )
    if outlet_id is not None and not outlets:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Point de vente introuvable.")

    # Ce que chaque ligne vendue a fait sortir du stock, au cout fige sur la
    # sortie -- ou, pour les sorties d'avant, au cout du produit aujourd'hui.
    cout_fige = case(
        (StockMovement.unit_cost > 0, StockMovement.unit_cost), else_=unit_cost_sql()
    )
    sorties = (
        select(
            StockMovement.source_id.label("item_id"),
            StockMovement.product_id.label("product_id"),
            func.sum(StockMovement.quantity * cout_fige).label("cost"),
        )
        .join(Product, Product.id == StockMovement.product_id)
        .where(
            StockMovement.hotel_id == user.hotel_id,
            StockMovement.deleted_at.is_(None),
            StockMovement.source_table == "folio_items",
            StockMovement.type == StockMovementType.OUT,
        )
        .group_by(StockMovement.source_id, StockMovement.product_id)
        .subquery()
    )
    lignes = await session.execute(
        select(
            FolioItem.source_id,
            sorties.c.product_id,
            FolioItem.label,
            func.sum(FolioItem.quantity),
            func.sum(FolioItem.amount),
            func.sum(sorties.c.cost),
        )
        .join(Folio, Folio.id == FolioItem.folio_id)
        .outerjoin(sorties, sorties.c.item_id == FolioItem.id)
        .where(
            Folio.hotel_id == user.hotel_id,
            Folio.deleted_at.is_(None),
            FolioItem.deleted_at.is_(None),
            FolioItem.is_void.is_(False),
            # Une vente garde son point de vente, meme portee sur la chambre.
            FolioItem.source_table == "outlets",
            FolioItem.source_id.in_([o.id for o in outlets]),
            FolioItem.business_date >= date_from,
            FolioItem.business_date <= date_to,
        )
        .group_by(FolioItem.source_id, sorties.c.product_id, FolioItem.label)
        .order_by(func.sum(FolioItem.amount).desc(), FolioItem.label)
    )

    vendus: dict[uuid.UUID, list[SoldProductMarginOut]] = {o.id: [] for o in outlets}
    for outlet, product_id, label, quantity, revenue, cost in lignes.all():
        # SUM(bigint) renvoie un numeric (Decimal) : on reste en francs entiers.
        revenue = int(revenue or 0)
        cost = int(cost) if cost is not None else None
        vendus[outlet].append(
            SoldProductMarginOut(
                product_id=product_id,
                label=label,
                quantity=int(quantity or 0),
                revenue=revenue,
                cost=cost,
                margin=revenue - cost if cost is not None else None,
            )
        )

    rapport = []
    for o in outlets:
        produits = vendus[o.id]
        revenue = sum(p.revenue for p in produits)
        sans_cout = sum(p.revenue for p in produits if p.cost is None)
        cost = sum(p.cost for p in produits if p.cost is not None)
        margin = revenue - sans_cout - cost
        rapport.append(
            OutletMarginOut(
                outlet_id=o.id,
                code=o.code,
                label=o.label,
                revenue=revenue,
                uncosted_revenue=sans_cout,
                cost=cost,
                margin=margin,
                margin_rate_bp=margin_rate_bp(margin, revenue - sans_cout),
                products=produits,
            )
        )

    revenue = sum(o.revenue for o in rapport)
    sans_cout = sum(o.uncosted_revenue for o in rapport)
    cost = sum(o.cost for o in rapport)
    margin = revenue - sans_cout - cost
    return MarginReportOut(
        date_from=date_from,
        date_to=date_to,
        revenue=revenue,
        uncosted_revenue=sans_cout,
        cost=cost,
        margin=margin,
        margin_rate_bp=margin_rate_bp(margin, revenue - sans_cout),
        outlets=rapport,
    )


@router.get("/stock-value", response_model=StockValueOut)
async def stock_value(
    stock_location_id: uuid.UUID | None = Query(default=None, description="Un seul magasin"),
    session: AsyncSession = Depends(get_session),
    # L'econome tient ce stock : il en lit la valeur (decision du 14
    # octobre). Les marges, elles, restent a `accounting.read` seul.
    user: User = Depends(require_any_permission("accounting.read", "stock.manage")),
) -> StockValueOut:
    """Ce que vaut le stock de chaque magasin, au cout moyen de chaque produit."""
    stmt = select(StockLocation).where(
        StockLocation.hotel_id == user.hotel_id, StockLocation.deleted_at.is_(None)
    )
    if stock_location_id is not None:
        stmt = stmt.where(StockLocation.id == stock_location_id)
    magasins = list(
        (
            await session.scalars(
                # L'economat d'abord : c'est lui qu'on vient lire.
                stmt.order_by(
                    StockLocation.is_central.desc(),
                    StockLocation.sort_order,
                    StockLocation.label,
                    StockLocation.id,
                )
            )
        ).all()
    )
    if stock_location_id is not None and not magasins:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Magasin introuvable.")

    niveaux = await session.execute(
        select(StockLevel, Product)
        .join(Product, Product.id == StockLevel.product_id)
        .where(
            StockLevel.stock_location_id.in_([m.id for m in magasins]),
            Product.hotel_id == user.hotel_id,
            Product.deleted_at.is_(None),
            # Un stock negatif est un comptage en retard (livraison pas encore
            # saisie), pas une dette : il vaut zero, il ne retire rien a la
            # valeur des autres produits.
            StockLevel.quantity > 0,
        )
        .order_by(Product.label, Product.id)
    )
    lignes: dict[uuid.UUID, list[StockValueLineOut]] = {m.id: [] for m in magasins}
    for niveau, produit in niveaux.all():
        cout = unit_cost_of(produit)
        lignes[niveau.stock_location_id].append(
            StockValueLineOut(
                product_id=produit.id,
                reference=produit.reference,
                label=produit.label,
                quantity=niveau.quantity,
                unit_cost=cout,
                value=niveau.quantity * cout,
            )
        )

    locations = [
        LocationStockValueOut(
            stock_location_id=m.id,
            code=m.code,
            label=m.label,
            outlet_id=m.outlet_id,
            is_central=m.is_central,
            value=sum(ligne.value for ligne in lignes[m.id]),
            products=lignes[m.id],
        )
        for m in magasins
    ]
    return StockValueOut(value=sum(m.value for m in locations), locations=locations)


@router.get("/daily-costs", response_model=list[DailyCostOut])
async def daily_costs(
    since: dt.date = Query(description="Premiere journee hoteliere incluse"),
    until: dt.date | None = Query(
        default=None,
        description="Derniere journee incluse ; par defaut, la journee en cours",
    ),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("accounting.read")),
) -> list[DailyCostOut]:
    """Ce que chaque journee a coute en stock, pour le benefice.

    La tablette calcule ses rapports hors ligne, sur sa base ; les mouvements
    de stock, eux, ne descendent pas (seuls les transferts a valider le
    font). Elle garde donc ces totaux, une ligne par journee.

    Le cout d'une vente est celui de sa journee de vente, au cout fige sur la
    sortie (la meme regle que `/margins`). Le reste -- achats, ce qui est
    utilise, pertes -- se date de la journee hoteliere de son mouvement.
    """
    if until is None:
        until = await current_business_date(session, user.hotel_id)
    if since > until:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "since est apres until."
        )
    hotel = await session.get(Hotel, user.hotel_id)
    cout = case(
        (StockMovement.unit_cost > 0, StockMovement.unit_cost), else_=unit_cost_sql()
    )
    jours: dict[dt.date, dict[str, int]] = {}

    def ligne(jour: dt.date) -> dict[str, int]:
        return jours.setdefault(
            jour, {"cost_of_sales": 0, "consumption": 0, "losses": 0, "purchases": 0}
        )

    ventes = await session.execute(
        select(FolioItem.business_date, func.sum(StockMovement.quantity * cout))
        .select_from(StockMovement)
        .join(Product, Product.id == StockMovement.product_id)
        .join(FolioItem, FolioItem.id == StockMovement.source_id)
        .where(
            StockMovement.hotel_id == user.hotel_id,
            StockMovement.deleted_at.is_(None),
            StockMovement.source_table == "folio_items",
            StockMovement.type == StockMovementType.OUT,
            FolioItem.deleted_at.is_(None),
            FolioItem.is_void.is_(False),
            FolioItem.business_date >= since,
            FolioItem.business_date <= until,
        )
        .group_by(FolioItem.business_date)
    )
    for jour, montant in ventes.all():
        ligne(jour)["cost_of_sales"] += int(montant or 0)

    # La journee hoteliere d'un instant : l'heure locale de l'hotel, moins
    # l'heure de bascule. Avant 6 h, c'est encore la veille.
    journee = cast(
        func.timezone(hotel.timezone, StockMovement.moved_at)
        - dt.timedelta(hours=hotel.day_rollover_hour),
        Date,
    )
    autres = await session.execute(
        select(journee, StockMovement.type, func.sum(StockMovement.quantity * cout))
        .join(Product, Product.id == StockMovement.product_id)
        .where(
            StockMovement.hotel_id == user.hotel_id,
            StockMovement.deleted_at.is_(None),
            StockMovement.status == StockMovementStatus.APPROVED,
            StockMovement.type.in_(
                [StockMovementType.IN, StockMovementType.OUT, StockMovementType.LOSS]
            ),
            # Les sorties des ventes sont comptees plus haut, a leur journee.
            (StockMovement.source_table.is_(None))
            | (StockMovement.source_table != "folio_items"),
            journee >= since,
            journee <= until,
        )
        .group_by(journee, StockMovement.type)
    )
    rubrique = {
        StockMovementType.IN: "purchases",
        StockMovementType.OUT: "consumption",
        StockMovementType.LOSS: "losses",
    }
    for jour, genre, montant in autres.all():
        ligne(jour)[rubrique[StockMovementType(genre)]] += int(montant or 0)

    return [DailyCostOut(business_date=jour, **jours[jour]) for jour in sorted(jours)]
