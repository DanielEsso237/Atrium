"""Routes referentiel impression : imprimantes, types de documents, routage,

modeles (paragraphe 4.2 du cahier des charges, regles R1-R5).
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_permission
from app.db.session import get_session
from app.models import DocumentTemplate, DocumentType, PrintRoute, Printer, User
from app.schemas.printing import (
    DocumentTemplateIn,
    DocumentTemplateOut,
    DocumentTypeIn,
    DocumentTypeOut,
    PrinterIn,
    PrinterOut,
    PrintRouteIn,
    PrintRouteOut,
)

router = APIRouter(tags=["impression"])


async def _create_or_422(session: AsyncSession, obj) -> None:
    """Les routes de ce fichier referencent beaucoup d'autres tables

    (document_type_id, printer_id, prep_station_id...) : plutot que de
    verifier chaque cle etrangere a la main avant insertion, on laisse
    PostgreSQL le faire et on traduit l'echec en reponse claire.
    """
    session.add(obj)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "Reference invalide (verifie les identifiants fournis).",
        ) from exc


# --- Imprimantes -----------------------------------------------------------------


@router.get(
    "/printers",
    response_model=list[PrinterOut],
)
async def list_printers(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.read")),
) -> list[Printer]:
    result = await session.execute(
        select(Printer)
        .where(
            Printer.hotel_id == user.hotel_id,
            Printer.deleted_at.is_(None),
        )
        .order_by(Printer.logical_name)
    )
    return list(result.scalars().all())


@router.post("/printers", response_model=PrinterOut, status_code=status.HTTP_201_CREATED)
async def create_printer(
    payload: PrinterIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.write")),
) -> Printer:
    printer = Printer(hotel_id=user.hotel_id, **payload.model_dump())
    await _create_or_422(session, printer)
    await session.refresh(printer)
    return printer


@router.patch("/printers/{printer_id}", response_model=PrinterOut)
async def update_printer(
    printer_id: uuid.UUID,
    payload: PrinterIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.write")),
) -> Printer:
    """Remplacer une imprimante en panne : on change `host`/`port` (ou

    `device_path`) sur la meme ligne, `logical_name` ne bouge pas -- c'est
    exactement ce que la regle R4 est censee eviter de devoir faire ailleurs.
    """
    printer = await session.get(Printer, printer_id)
    if printer is None or printer.hotel_id != user.hotel_id or printer.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Imprimante introuvable.")
    for field, value in payload.model_dump().items():
        setattr(printer, field, value)
    await session.commit()
    await session.refresh(printer)
    return printer


# --- Types de documents -----------------------------------------------------------


@router.get(
    "/document-types",
    response_model=list[DocumentTypeOut],
)
async def list_document_types(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.read")),
) -> list[DocumentType]:
    result = await session.execute(
        select(DocumentType)
        .where(
            DocumentType.hotel_id == user.hotel_id,
            DocumentType.deleted_at.is_(None),
        )
        .order_by(DocumentType.label)
    )
    return list(result.scalars().all())


@router.post(
    "/document-types", response_model=DocumentTypeOut, status_code=status.HTTP_201_CREATED
)
async def create_document_type(
    payload: DocumentTypeIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.write")),
) -> DocumentType:
    doc_type = DocumentType(hotel_id=user.hotel_id, **payload.model_dump())
    await _create_or_422(session, doc_type)
    await session.refresh(doc_type)
    return doc_type


# --- Regles de routage (R5) --------------------------------------------------------


@router.get(
    "/print-routes",
    response_model=list[PrintRouteOut],
)
async def list_print_routes(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.read")),
) -> list[PrintRoute]:
    result = await session.execute(
        select(PrintRoute)
        .where(
            PrintRoute.hotel_id == user.hotel_id,
            PrintRoute.deleted_at.is_(None),
        )
        .order_by(PrintRoute.document_type_id, PrintRoute.priority.desc())
    )
    return list(result.scalars().all())


@router.post(
    "/print-routes", response_model=PrintRouteOut, status_code=status.HTTP_201_CREATED
)
async def create_print_route(
    payload: PrintRouteIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.write")),
) -> PrintRoute:
    """C'est ici que R5 (routage configurable) prend tout son sens : ouvrir

    un nouveau point de vente ou deplacer une imprimante se traduit par une
    regle de plus, jamais par une modification de code applicatif.
    """
    route = PrintRoute(hotel_id=user.hotel_id, **payload.model_dump())
    await _create_or_422(session, route)
    await session.refresh(route)
    return route


# --- Modeles de documents ------------------------------------------------------------


@router.get(
    "/document-templates",
    response_model=list[DocumentTemplateOut],
)
async def list_document_templates(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.read")),
) -> list[DocumentTemplate]:
    result = await session.execute(
        select(DocumentTemplate)
        .where(
            DocumentTemplate.hotel_id == user.hotel_id,
            DocumentTemplate.deleted_at.is_(None),
        )
        .order_by(DocumentTemplate.document_type_id, DocumentTemplate.version.desc())
    )
    return list(result.scalars().all())


@router.post(
    "/document-templates",
    response_model=DocumentTemplateOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_document_template(
    payload: DocumentTemplateIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_permission("printing.write")),
) -> DocumentTemplate:
    """Chaque creation ouvre une nouvelle version plutot que d'ecraser la

    precedente (voir le commentaire du modele `DocumentTemplate`) : une
    reimpression tardive doit pouvoir reproduire la mise en page de l'epoque.
    """
    next_version = (
        await session.scalar(
            select(func.count())
            .select_from(DocumentTemplate)
            .where(DocumentTemplate.document_type_id == payload.document_type_id)
        )
        or 0
    ) + 1
    template = DocumentTemplate(
        hotel_id=user.hotel_id, version=next_version, **payload.model_dump()
    )
    await _create_or_422(session, template)
    await session.refresh(template)
    return template
