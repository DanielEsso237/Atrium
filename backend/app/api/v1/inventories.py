"""L'inventaire d'un magasin (ticket O4, demande du 15 octobre).

Le charge d'inventaire ouvre l'inventaire d'un magasin, compte sur le terrain
et saisit ce qu'il trouve ; un responsable « reequilibre » : le stock
theorique s'aligne sur le reel. Tout arrive de la file d'une tablette.

Decisions de Daniel (15 octobre) :

- **un seul inventaire ouvert par magasin** (409 sinon) ;
- **la quantite theorique est figee a l'ouverture**, par le serveur : on
  compte magasin ferme, et ce qui se vend ensuite reste vendu ;
- **deux droits** : `stock.inventory` ouvre, compte et abandonne ;
  `stock.rebalance` reequilibre ;
- au reequilibrage, **un manque devient une perte** (`LOSS`, comptee dans le
  benefice), **un surplus un ajustement** (`ADJUSTMENT`). Les lignes non
  comptees ne bougent pas.

**Chaque route est rejouable.** Un renvoi rend l'etat deja atteint, sans rien
refaire ni rien refuser : un refus bloquerait la file de la tablette.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.core.ids import uuid7
from app.db.session import get_session
from app.models import (
    Inventory,
    InventoryLine,
    Product,
    StockLevel,
    StockLocation,
    StockMovement,
    User,
)
from app.models.enums import InventoryStatus, StockMovementStatus, StockMovementType
from app.schemas.inventory import (
    InventoryCountIn,
    InventoryIn,
    InventoryOut,
    InventoryRebalanceIn,
)
from app.services.business_day import current_business_date
from app.services.costing import unit_cost_of
from app.services.stock_levels import apply_movement

router = APIRouter(prefix="/inventories", tags=["inventaire"])


async def _inventaire(
    session: AsyncSession, inventory_id: uuid.UUID, user: User
) -> Inventory:
    inv = await session.get(Inventory, inventory_id, with_for_update=True)
    if inv is None or inv.hotel_id != user.hotel_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Inventaire introuvable.")
    return inv


@router.get("", response_model=list[InventoryOut])
async def list_inventories(
    since: dt.datetime | None = Query(
        default=None, description="Modifies depuis cet instant, abandonnes compris"
    ),
    stock_location_id: uuid.UUID | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.read")),
) -> list[Inventory]:
    """La descente : les inventaires de l'hotel, avec leurs lignes.

    Les abandonnes viennent aussi : une tablette qui en connait un ouvert
    doit apprendre qu'il ne l'est plus. Sans `since`, ceux encore ouverts.
    """
    stmt = select(Inventory).where(Inventory.hotel_id == user.hotel_id)
    if since is not None:
        stmt = stmt.where(Inventory.updated_at >= since)
    else:
        stmt = stmt.where(
            Inventory.deleted_at.is_(None),
            Inventory.status != InventoryStatus.CLOSED,
        )
    if stock_location_id is not None:
        stmt = stmt.where(Inventory.stock_location_id == stock_location_id)
    result = await session.scalars(stmt.order_by(Inventory.created_at))
    return list(result.all())


@router.get("/{inventory_id}", response_model=InventoryOut)
async def get_inventory(
    inventory_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.read")),
) -> Inventory:
    inv = await session.get(Inventory, inventory_id)
    if inv is None or inv.hotel_id != user.hotel_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Inventaire introuvable.")
    return inv


@router.post(
    "",
    response_model=InventoryOut,
    status_code=status.HTTP_201_CREATED,
    responses={
        200: {"description": "Inventaire deja ouvert avec cet id : etat actuel"},
        409: {"description": "Un autre inventaire est ouvert sur ce magasin"},
    },
)
async def open_inventory(
    payload: InventoryIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.inventory")),
) -> Inventory:
    """Ouvre l'inventaire d'un magasin et fige la quantite theorique."""
    existant = await session.get(Inventory, payload.id)
    if existant is not None:
        if existant.hotel_id != user.hotel_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifiant inconnu.")
        response.status_code = status.HTTP_200_OK
        return existant

    # Le magasin verrouille : deux ouvertures simultanees du meme magasin ne
    # passent pas toutes les deux le controle ci-dessous.
    magasin = await session.get(StockLocation, payload.stock_location_id, with_for_update=True)
    if magasin is None or magasin.hotel_id != user.hotel_id or magasin.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Magasin introuvable.")
    ouvert = await session.scalar(
        select(Inventory.id).where(
            Inventory.stock_location_id == magasin.id,
            Inventory.deleted_at.is_(None),
            Inventory.status != InventoryStatus.CLOSED,
        )
    )
    if ouvert is not None:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Un inventaire est deja ouvert pour {magasin.label}.",
        )

    produits = {line.product_id for line in payload.lines}
    if len(produits) != len(payload.lines):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "Un article apparait deux fois."
        )
    connus = set(
        (
            await session.scalars(
                select(Product.id).where(
                    Product.id.in_(produits), Product.hotel_id == user.hotel_id
                )
            )
        ).all()
    )
    if connus != produits:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Article introuvable.")
    niveaux = dict(
        (
            await session.execute(
                select(StockLevel.product_id, StockLevel.quantity).where(
                    StockLevel.stock_location_id == magasin.id,
                    StockLevel.product_id.in_(produits),
                )
            )
        ).all()
    )

    now = dt.datetime.now(dt.timezone.utc)
    inv = Inventory(
        id=payload.id,
        hotel_id=user.hotel_id,
        stock_location_id=magasin.id,
        label=payload.label,
        status=InventoryStatus.COUNTING,
        inventory_date=await current_business_date(session, user.hotel_id),
        started_at=now,
        created_by=user.id,
    )
    session.add(inv)
    await session.flush()
    for line in payload.lines:
        session.add(
            InventoryLine(
                id=line.id,
                inventory_id=inv.id,
                product_id=line.product_id,
                theoretical_qty=niveaux.get(line.product_id, 0),
                created_by=user.id,
            )
        )
    await session.commit()
    await session.refresh(inv, attribute_names=["lines"])
    return inv


@router.put("/{inventory_id}/lines/{product_id}", response_model=InventoryOut)
async def count_line(
    inventory_id: uuid.UUID,
    product_id: uuid.UUID,
    payload: InventoryCountIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.inventory")),
) -> Inventory:
    """Ce qui a ete compte pour un article, et le motif de l'ecart.

    Seuls les champs envoyes changent : `counted_qty` ou `comment` absent
    reste tel quel, `null` l'efface.
    """
    inv = await _inventaire(session, inventory_id, user)
    ligne = next((l for l in inv.lines if l.product_id == product_id), None)
    if ligne is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Article absent de cet inventaire.")
    champs = payload.model_dump(exclude_unset=True)
    if all(getattr(ligne, nom) == valeur for nom, valeur in champs.items()):
        # Renvoi d'un comptage deja passe, meme sur un inventaire clos depuis.
        return inv
    if inv.deleted_at is not None or inv.status == InventoryStatus.CLOSED:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cet inventaire n'est plus ouvert.")
    if "counted_qty" in champs:
        ligne.counted_qty = champs["counted_qty"]
        ligne.variance = (
            0 if ligne.counted_qty is None else ligne.counted_qty - ligne.theoretical_qty
        )
    if "comment" in champs:
        ligne.comment = champs["comment"]
    ligne.updated_by = user.id
    inv.updated_by = user.id
    # La descente lit `updated_at` de l'inventaire : un comptage le touche.
    inv.updated_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()
    await session.refresh(inv, attribute_names=["lines"])
    return inv


@router.post("/{inventory_id}/rebalance", response_model=InventoryOut)
async def rebalance_inventory(
    inventory_id: uuid.UUID,
    payload: InventoryRebalanceIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.rebalance")),
) -> Inventory:
    """Aligne le stock du magasin sur ce qui a ete compte, puis clot.

    L'ecart se calcule sur la quantite theorique du serveur, figee a
    l'ouverture. Un ecart que la tablette n'avait pas vu (une vente faite
    ailleurs) prend un id du serveur ; un id de la tablette sans ecart ici
    reste inutilise.
    """
    inv = await _inventaire(session, inventory_id, user)
    if inv.status == InventoryStatus.CLOSED:
        return inv
    if inv.deleted_at is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cet inventaire a ete abandonne.")
    comptees = [l for l in inv.lines if l.counted_qty is not None and l.deleted_at is None]
    if not comptees:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "Comptez au moins un article avant de reequilibrer.",
        )

    now = dt.datetime.now(dt.timezone.utc)
    for ligne in comptees:
        ecart = ligne.counted_qty - ligne.theoretical_qty
        if ecart == 0:
            continue
        produit = await session.get(Product, ligne.product_id)
        mouvement = StockMovement(
            id=payload.movement_ids.get(ligne.product_id) or uuid7(),
            hotel_id=user.hotel_id,
            product_id=ligne.product_id,
            stock_location_id=inv.stock_location_id,
            type=StockMovementType.LOSS if ecart < 0 else StockMovementType.ADJUSTMENT,
            # Une perte se compte en positif, comme toute sortie ; un
            # ajustement porte son signe (`apply_movement`).
            quantity=-ecart if ecart < 0 else ecart,
            # Le cout du jour, fige : la perte garde sa valeur dans le benefice.
            unit_cost=unit_cost_of(produit) if produit is not None else 0,
            reason=inv.label,
            source_table="inventories",
            source_id=inv.id,
            moved_at=now,
            moved_by=user.id,
            status=StockMovementStatus.APPROVED,
        )
        session.add(mouvement)
        await apply_movement(session, mouvement)
    inv.status = InventoryStatus.CLOSED
    inv.closed_at = now
    inv.closed_by = user.id
    inv.updated_by = user.id
    await session.commit()
    await session.refresh(inv, attribute_names=["lines"])
    return inv


@router.post("/{inventory_id}/cancel", response_model=InventoryOut)
async def cancel_inventory(
    inventory_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("stock.inventory")),
) -> Inventory:
    """Abandonne un inventaire ouvert : rien ne bouge dans le stock."""
    inv = await _inventaire(session, inventory_id, user)
    if inv.deleted_at is not None:
        return inv
    if inv.status == InventoryStatus.CLOSED:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cet inventaire est deja clos.")
    inv.deleted_at = dt.datetime.now(dt.timezone.utc)
    inv.updated_by = user.id
    await session.commit()
    await session.refresh(inv, attribute_names=["lines"])
    return inv
