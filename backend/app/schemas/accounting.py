"""Schemas Pydantic des marges et de la valeur du stock.

Tous les montants sont des francs CFA entiers ; les taux sont en points de
base (35 % -> 3500).
"""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, Field


class ProductMarginOut(BaseModel):
    """Ce qu'une unite du produit rapporte au prix de la carte."""

    product_id: uuid.UUID
    reference: str
    label: str
    purchase_price: int
    average_cost: int = Field(description="Cout moyen pondere ; 0 sans entree valorisee")
    unit_cost: int = Field(description="Le cout retenu : cout moyen, sinon prix d'achat")
    sale_price: int
    margin: int = Field(description="sale_price - unit_cost")
    margin_rate_bp: int | None = Field(description="Marge / prix de vente ; nul sans prix de vente")


class SoldProductMarginOut(BaseModel):
    """Un article vendu par un point de vente sur la periode."""

    product_id: uuid.UUID | None = Field(
        description="Le produit sorti du stock ; nul si l'article ne se stocke pas"
    )
    label: str
    quantity: int
    revenue: int
    cost: int | None = Field(description="Nul quand le cout n'est pas connu")
    margin: int | None


class OutletMarginOut(BaseModel):
    outlet_id: uuid.UUID
    code: str
    label: str
    revenue: int = Field(description="Tout ce que le point de vente a vendu")
    # Un plat du jour, un service : ils ne sortent d'aucun stock, leur cout
    # n'est pas connu. Les compter dans la marge les donnerait pour gratuits.
    uncosted_revenue: int = Field(description="La part de la recette sans cout connu")
    cost: int = Field(description="Cout de ce qui est sorti du stock pour ces ventes")
    margin: int = Field(description="(revenue - uncosted_revenue) - cost")
    margin_rate_bp: int | None = Field(description="Marge / recette dont le cout est connu")
    products: list[SoldProductMarginOut]


class MarginReportOut(BaseModel):
    date_from: dt.date
    date_to: dt.date
    revenue: int
    uncosted_revenue: int
    cost: int
    margin: int
    margin_rate_bp: int | None
    outlets: list[OutletMarginOut]


class StockValueLineOut(BaseModel):
    product_id: uuid.UUID
    reference: str
    label: str
    quantity: int
    unit_cost: int
    value: int


class LocationStockValueOut(BaseModel):
    stock_location_id: uuid.UUID
    code: str
    label: str
    outlet_id: uuid.UUID | None
    is_central: bool
    value: int
    products: list[StockValueLineOut]


class StockValueOut(BaseModel):
    value: int
    locations: list[LocationStockValueOut]


class DailyCostOut(BaseModel):
    """Ce qu'une journee hoteliere a coute en stock, en francs entiers.

    - `cost_of_sales` : ce que les lignes vendues ce jour-la ont fait sortir ;
    - `consumption` : ce qui est sorti sans etre vendu (cuisine, chambres,
      spa) ;
    - `losses` : la casse et les pertes ;
    - `purchases` : ce que les livraisons ont coute. A titre indicatif : un
      achat n'est un cout qu'une fois vendu ou utilise, ce qui reste en
      stock garde sa valeur.
    """

    business_date: dt.date
    cost_of_sales: int
    consumption: int
    losses: int
    purchases: int
