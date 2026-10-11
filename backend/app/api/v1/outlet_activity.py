"""L'activite des points de vente, pour le tableau de bord de leurs agents.

Un agent de point de vente ne lit ni les ardoises ni les encaissements de
l'hotel (`folio.read`) : sans cette route, son tableau de bord ne montrait
que ce qui avait ete vendu sur sa propre tablette. Elle lui donne ce que ses
points de vente ont vendu et encaisse, sur tous les postes, et rien d'autre :
les lignes de ses points de vente, pas les ardoises entieres.

Le perimetre est celui de `user_outlets` : un agent rattache voit les siens,
un agent sans rattachement (reception, direction) les voit tous.
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, Query
from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.api.v1.cash_sessions import in_window
from app.db.session import get_session
from app.models import CashSession, Folio, FolioItem, Payment, User
from app.schemas.billing import FolioItemOut, PaymentOut
from app.schemas.cash_sessions import CashSessionOut
from app.schemas.outlet_activity import OutletActivityOut, OutletSaleOut
from app.services.outlets import allowed_outlet_ids

router = APIRouter(prefix="/outlet-activity", tags=["points de vente"])


@router.get("", response_model=OutletActivityOut)
async def outlet_activity(
    since: dt.date = Query(description="Premiere journee hoteliere incluse"),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("order.read")),
) -> OutletActivityOut:
    allowed = await allowed_outlet_ids(session, user)

    def du_perimetre(colonne):
        # Sans rattachement : tous les points de vente, mais seulement eux --
        # une ligne ou un tiroir sans point de vente n'est pas de leur ressort.
        return colonne.is_not(None) if allowed is None else colonne.in_(allowed)

    lignes = await session.execute(
        select(FolioItem, Folio)
        .join(Folio, Folio.id == FolioItem.folio_id)
        .where(
            Folio.hotel_id == user.hotel_id,
            Folio.deleted_at.is_(None),
            FolioItem.deleted_at.is_(None),
            FolioItem.source_table == "outlets",
            du_perimetre(FolioItem.source_id),
            FolioItem.business_date >= since,
        )
        .order_by(FolioItem.business_date, FolioItem.posted_at.nullsfirst(), FolioItem.id)
    )
    sales = [
        OutletSaleOut.model_validate(
            {
                **FolioItemOut.model_validate(item).model_dump(),
                "folio_id": folio.id,
                "folio_number": folio.number,
                "folio_type": folio.type,
                "folio_status": folio.status,
            }
        )
        for item, folio in lignes.all()
    ]

    tiroirs = select(CashSession.id).where(
        CashSession.hotel_id == user.hotel_id,
        du_perimetre(CashSession.outlet_id),
    )
    encaissements = await session.scalars(
        select(Payment)
        .where(
            Payment.hotel_id == user.hotel_id,
            Payment.deleted_at.is_(None),
            Payment.cash_session_id.in_(tiroirs),
            # Meme fenetre que `GET /payments`.
            or_(
                Payment.business_date >= since,
                and_(
                    Payment.business_date.is_(None),
                    Payment.received_at
                    >= dt.datetime.combine(since, dt.time.min, tzinfo=dt.timezone.utc),
                ),
            ),
        )
        .order_by(Payment.received_at.asc().nullsfirst(), Payment.id)
    )

    caisses = await session.scalars(
        select(CashSession)
        .where(
            CashSession.hotel_id == user.hotel_id,
            CashSession.deleted_at.is_(None),
            du_perimetre(CashSession.outlet_id),
            in_window(since),
        )
        .order_by(CashSession.opened_at.asc().nullsfirst(), CashSession.id)
    )

    return OutletActivityOut(
        sales=sales,
        payments=[PaymentOut.model_validate(p) for p in encaissements],
        cash_sessions=[CashSessionOut.model_validate(c) for c in caisses],
    )
