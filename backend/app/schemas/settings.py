"""La regle des arrhes, au format fixe par `services/deposit.py`.

    {"mode": "FIXED", "amount": 20000}     somme fixe en FCFA
    {"mode": "PERCENT", "rate_bp": 3000}   30 % du sejour, en points de base

Validee ici, strictement : une regle mal formee ne ferait pas d'erreur a
l'ecriture, elle serait lue comme « pas d'arrhes » a chaque reservation, en
silence.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, model_validator


class DepositRule(BaseModel):
    mode: Literal["FIXED", "PERCENT"]
    amount: int | None = Field(default=None, gt=0, description="FCFA, mode FIXED")
    rate_bp: int | None = Field(
        default=None, gt=0, le=10_000, description="Points de base, mode PERCENT (3000 = 30 %)"
    )

    @model_validator(mode="after")
    def _un_seul_parametre(self) -> DepositRule:
        if self.mode == "FIXED" and (self.amount is None or self.rate_bp is not None):
            raise ValueError("Le mode FIXED exige `amount` et rien d'autre.")
        if self.mode == "PERCENT" and (self.rate_bp is None or self.amount is not None):
            raise ValueError("Le mode PERCENT exige `rate_bp` et rien d'autre.")
        return self

    def as_setting(self) -> dict:
        if self.mode == "FIXED":
            return {"mode": "FIXED", "amount": self.amount}
        return {"mode": "PERCENT", "rate_bp": self.rate_bp}


class DepositRuleOut(BaseModel):
    rule: dict | None
