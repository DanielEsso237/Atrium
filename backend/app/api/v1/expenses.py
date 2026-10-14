"""Les depenses de l'hotel hors stock : salaires, electricite, eau, loyer...

Elles font du benefice le vrai benefice : les recettes, moins ce que coute ce
qui est vendu, moins ce qui est utilise, moins elles.

Lire : `accounting.read`, comme les marges -- une depense dit autant qu'une
recette, le comptoir ne la voit pas. Saisir, corriger, annuler :
`expense.write` (administration, direction, comptable).

Une depense ne se supprime pas : elle s'annule avec un motif, et reste.

**Les refus, la tablette les applique avant d'enfiler** (`ExpenseRepository`) :
un montant nul ou demesure, une date future, une depense annulee qu'on
corrigerait. Un refus qui arriverait par la file la bloquerait.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import Expense, User
from app.schemas.expenses import ExpenseIn, ExpenseOut, ExpenseUpdate, ExpenseVoidIn
from app.services.business_day import current_business_date
from app.core.ids import uuid7

router = APIRouter(prefix="/expenses", tags=["depenses"])


async def _depense(session: AsyncSession, expense_id: uuid.UUID, user: User) -> Expense:
    depense = await session.get(Expense, expense_id)
    if (
        depense is None
        or depense.hotel_id != user.hotel_id
        or depense.deleted_at is not None
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Depense introuvable.")
    return depense


async def _pas_dans_le_futur(session: AsyncSession, user: User, jour: dt.date) -> None:
    # Une depense se saisit quand elle est payee. Une date a venir est une
    # faute de saisie, et elle fausserait le benefice d'un mois pas encore vecu.
    if jour > await current_business_date(session, user.hotel_id):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "Une depense ne peut pas etre datee du futur.",
        )


@router.get("", response_model=list[ExpenseOut])
async def list_expenses(
    since: dt.date | None = Query(default=None, description="Premiere journee incluse"),
    until: dt.date | None = Query(default=None, description="Derniere journee incluse"),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("accounting.read")),
) -> list[Expense]:
    """Les annulees comprises : une tablette doit apprendre qu'une depense
    qu'elle connait a ete annulee ailleurs."""
    stmt = select(Expense).where(
        Expense.hotel_id == user.hotel_id, Expense.deleted_at.is_(None)
    )
    if since is not None:
        stmt = stmt.where(Expense.business_date >= since)
    if until is not None:
        stmt = stmt.where(Expense.business_date <= until)
    result = await session.scalars(
        stmt.order_by(Expense.business_date, Expense.created_at)
    )
    return list(result.all())


@router.post(
    "",
    response_model=ExpenseOut,
    status_code=status.HTTP_201_CREATED,
    responses={200: {"description": "Depense deja enregistree (meme id)"}},
)
async def create_expense(
    payload: ExpenseIn,
    response: Response,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("expense.write")),
) -> Expense:
    if payload.id is not None:
        existante = await session.get(Expense, payload.id)
        if existante is not None:
            if existante.hotel_id != user.hotel_id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifiant inconnu.")
            response.status_code = status.HTTP_200_OK
            return existante
    await _pas_dans_le_futur(session, user, payload.business_date)
    depense = Expense(
        id=payload.id or uuid7(),
        hotel_id=user.hotel_id,
        recorded_by=user.id,
        **payload.model_dump(exclude={"id"}),
    )
    session.add(depense)
    await session.commit()
    await session.refresh(depense)
    return depense


@router.patch("/{expense_id}", response_model=ExpenseOut)
async def update_expense(
    expense_id: uuid.UUID,
    payload: ExpenseUpdate,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("expense.write")),
) -> Expense:
    depense = await _depense(session, expense_id, user)
    valeurs = payload.model_dump()
    if all(getattr(depense, cle) == valeur for cle, valeur in valeurs.items()):
        # Renvoi d'une correction deja passee : rien a refaire, meme si la
        # depense a ete annulee entre-temps. Le refuser bloquerait la file.
        return depense
    if depense.is_void:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cette depense est annulee.")
    await _pas_dans_le_futur(session, user, payload.business_date)
    for cle, valeur in valeurs.items():
        setattr(depense, cle, valeur)
    depense.updated_by = user.id
    await session.commit()
    await session.refresh(depense)
    return depense


@router.post("/{expense_id}/void", response_model=ExpenseOut)
async def void_expense(
    expense_id: uuid.UUID,
    payload: ExpenseVoidIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("expense.write")),
) -> Expense:
    depense = await _depense(session, expense_id, user)
    if depense.is_void:
        # Deja annulee : le premier motif fait foi.
        return depense
    depense.is_void = True
    depense.void_reason = payload.reason
    depense.voided_by = user.id
    depense.updated_by = user.id
    await session.commit()
    await session.refresh(depense)
    return depense
