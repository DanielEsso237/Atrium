"""Ce qu'un produit a coute : le cout moyen pondere.

Le prix d'achat d'un produit est le tarif du fournisseur, saisi a la main. Il
ne dit pas ce que vaut le stock : la caisse de bieres payee 500 la semaine
derniere et celle payee 600 ce matin sont melangees sur l'etagere. Le cout
moyen pondere les fond en un seul chiffre, recalcule a chaque entree :

    (stock d'avant x cout d'avant + quantite entree x prix de l'entree)
    ------------------------------------------------------------------
                    stock d'avant + quantite entree

Un cout par produit pour tout l'hotel, pas par magasin : un transfert de
l'economat au bar deplace des bouteilles, il ne change pas ce qu'elles ont
coute.

Tout est en francs entiers ; la division s'arrondit au franc le plus proche.
"""

from __future__ import annotations

import uuid
from decimal import ROUND_HALF_UP, Decimal

from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Product, StockLevel, StockMovement
from app.models.enums import StockMovementType


def weighted_average_cost(
    stock_before: int, cost_before: int, quantity_in: int, unit_cost: int
) -> int:
    """Le cout moyen apres une entree. Fonction pure : c'est elle qu'on teste.

    - Une entree sans prix (`unit_cost` a zero) ne dit rien : le cout ne
      bouge pas. La compter a zero ferait croire a des bieres gratuites.
    - Un stock vide ou negatif ne pese rien : ce qui manque n'a pas de cout a
      moyenner, l'entree fixe le cout a elle seule. De meme quand le cout
      d'avant est inconnu.
    """
    if quantity_in <= 0 or unit_cost <= 0:
        return cost_before
    if stock_before <= 0 or cost_before <= 0:
        return unit_cost
    total = stock_before * cost_before + quantity_in * unit_cost
    return _arrondi(Decimal(total) / (stock_before + quantity_in))


def unit_cost_of(product: Product) -> int:
    """Le cout d'une unite : le cout moyen, ou le prix d'achat tant qu'aucune
    entree valorisee ne l'a etabli."""
    return product.average_cost if product.average_cost > 0 else product.purchase_price


def unit_cost_sql():
    """La meme regle que `unit_cost_of`, pour les agregats en SQL."""
    return case((Product.average_cost > 0, Product.average_cost), else_=Product.purchase_price)


def margin_rate_bp(margin: int, revenue: int) -> int | None:
    """Le taux de marge en points de base (35 % -> 3500) ; nul sans recette."""
    if revenue <= 0:
        return None
    return _arrondi(Decimal(margin) * 10_000 / revenue)


def _arrondi(valeur: Decimal) -> int:
    return int(valeur.quantize(Decimal(1), rounding=ROUND_HALF_UP))


async def stock_on_hand(session: AsyncSession, product_id: uuid.UUID) -> int:
    """Ce que l'hotel detient du produit, tous magasins confondus."""
    total = await session.scalar(
        select(func.coalesce(func.sum(StockLevel.quantity), 0)).where(
            StockLevel.product_id == product_id
        )
    )
    return int(total or 0)


async def record_entry_cost(session: AsyncSession, movement: StockMovement) -> None:
    """Met a jour le cout moyen du produit pour une entree en stock.

    A appeler **avant** `apply_movement` : la moyenne se pondere par le stock
    d'avant la livraison. Seule une entree (IN) porte un prix d'achat ; un
    retour revient au cout qu'il avait, un ajustement corrige un comptage.
    """
    if movement.type != StockMovementType.IN or movement.unit_cost <= 0:
        return
    # Verrou sur le produit : deux livraisons du meme produit remontees en
    # meme temps doivent se moyenner l'une apres l'autre, pas l'une a la
    # place de l'autre.
    product = await session.get(Product, movement.product_id, with_for_update=True)
    if product is None:
        return
    product.average_cost = weighted_average_cost(
        await stock_on_hand(session, product.id),
        unit_cost_of(product),
        movement.quantity,
        movement.unit_cost,
    )
