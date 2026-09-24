"""Jeu de donnees de demonstration du serveur."""

from __future__ import annotations

import asyncio
import uuid

from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings
from app.core.security import hash_secret
from app.models import (
    DocumentType,
    Floor,
    Hotel,
    Permission,
    PrintRoute,
    Printer,
    Role,
    RolePermission,
    Room,
    RoomType,
    User,
    UserRole,
)
from app.models.enums import PrinterKind, PrinterProtocol

HOTEL = uuid.UUID("01920000-0000-7000-8000-000000000001")

FLOORS = [
    (uuid.UUID("01920000-0000-7000-8000-000000000101"), "E1", "Rez-de-chaussee", 1),
    (uuid.UUID("01920000-0000-7000-8000-000000000102"), "E2", "Premier etage", 2),
    (uuid.UUID("01920000-0000-7000-8000-000000000103"), "E3", "Deuxieme etage", 3),
    (uuid.UUID("01920000-0000-7000-8000-000000000104"), "E4", "Troisieme etage", 4),
    (uuid.UUID("01920000-0000-7000-8000-000000000105"), "E5", "Quatrieme etage", 5),
]
F1, F2, F3, F4, F5 = (f[0] for f in FLOORS)

STANDARD = uuid.UUID("01920000-0000-7000-8000-000000000201")
CLASSIC = uuid.UUID("01920000-0000-7000-8000-000000000202")
VIP = uuid.UUID("01920000-0000-7000-8000-000000000203")
SUITE = uuid.UUID("01920000-0000-7000-8000-000000000204")

ROOM_TYPES = [
    (STANDARD, "STD", "Standard", 2, 2, 25_000),
    (CLASSIC, "CLS", "Classic", 2, 3, 35_000),
    (VIP, "VIP", "VIP", 2, 3, 60_000),
    (SUITE, "SUI", "Suite", 2, 4, 90_000),
]

ROOMS = [
    ("101", STANDARD, F1), ("102", STANDARD, F1), ("103", CLASSIC, F1), ("123", STANDARD, F1),
    ("201", CLASSIC, F2), ("202", CLASSIC, F2), ("203", VIP, F2), ("204", STANDARD, F2),
    ("301", CLASSIC, F3), ("302", STANDARD, F3), ("309", VIP, F3),
    ("401", STANDARD, F4), ("402", CLASSIC, F4), ("403", VIP, F4),
    ("501", SUITE, F5), ("502", SUITE, F5), ("510", VIP, F5), ("567", STANDARD, F5),
]

ROLES = [
    (uuid.UUID("01920000-0000-7000-8000-000000004001"), "ADMIN", "Administrateur"),
    (uuid.UUID("01920000-0000-7000-8000-000000004002"), "RECEPTION", "Reception"),
    (uuid.UUID("01920000-0000-7000-8000-000000004003"), "CAISSE", "Caisse"),
    (uuid.UUID("01920000-0000-7000-8000-000000004004"), "RESTAURANT", "Restauration"),
    (uuid.UUID("01920000-0000-7000-8000-000000004005"), "HOUSEKEEPING", "Housekeeping"),
    (uuid.UUID("01920000-0000-7000-8000-000000004006"), "MAINTENANCE", "Maintenance"),
    (uuid.UUID("01920000-0000-7000-8000-000000004007"), "MANAGER", "Manager / Direction"),
]
ADMIN_ROLE, RECEPTION_ROLE = ROLES[0][0], ROLES[1][0]
CAISSE_ROLE = ROLES[2][0]
RESTAURANT_ROLE = ROLES[3][0]
HOUSEKEEPING_ROLE = ROLES[4][0]
MAINTENANCE_ROLE = ROLES[5][0]
MANAGER_ROLE = ROLES[6][0]

PERMISSIONS = [
    (uuid.UUID("01920000-0000-7000-8000-000000004101"), "reservation.create", "Creer une reservation", "reservation"),
    (uuid.UUID("01920000-0000-7000-8000-000000004102"), "folio.discount", "Appliquer une remise sur un folio", "folio"),
    (uuid.UUID("01920000-0000-7000-8000-000000004103"), "print.reprint", "Reimprimer un document (duplicata)", "print"),
    (uuid.UUID("01920000-0000-7000-8000-000000004104"), "rooms.read", "Consulter le plan des chambres", "rooms"),
    (uuid.UUID("01920000-0000-7000-8000-000000004105"), "guests.read", "Consulter les fiches clients", "guests"),
    (uuid.UUID("01920000-0000-7000-8000-000000004106"), "guests.write", "Creer ou modifier une fiche client", "guests"),
    (uuid.UUID("01920000-0000-7000-8000-000000004107"), "rooms.write", "Ajouter une chambre a l'inventaire", "rooms"),
    (uuid.UUID("01920000-0000-7000-8000-000000004108"), "room_types.read", "Consulter les categories de chambres", "room_types"),
    (uuid.UUID("01920000-0000-7000-8000-000000004109"), "room_types.write", "Creer ou revaloriser une categorie", "room_types"),
    (uuid.UUID("01920000-0000-7000-8000-000000004110"), "users.read", "Consulter le personnel", "users"),
    (uuid.UUID("01920000-0000-7000-8000-000000004111"), "users.write", "Creer ou modifier un compte personnel", "users"),
    (uuid.UUID("01920000-0000-7000-8000-000000004112"), "hotel.write", "Modifier le parametrage de l'etablissement", "hotel"),
    (uuid.UUID("01920000-0000-7000-8000-000000004113"), "stock.read", "Consulter le referentiel produits/stocks", "stock"),
    (uuid.UUID("01920000-0000-7000-8000-000000004114"), "stock.write", "Creer ou modifier le referentiel produits/stocks", "stock"),
    (uuid.UUID("01920000-0000-7000-8000-000000004115"), "restaurant.read", "Consulter le referentiel restauration", "restaurant"),
    (uuid.UUID("01920000-0000-7000-8000-000000004116"), "restaurant.write", "Creer ou modifier le referentiel restauration", "restaurant"),
    (uuid.UUID("01920000-0000-7000-8000-000000004117"), "printing.read", "Consulter le referentiel impression", "printing"),
    (uuid.UUID("01920000-0000-7000-8000-000000004118"), "printing.write", "Creer ou modifier le referentiel impression", "printing"),
    (uuid.UUID("01920000-0000-7000-8000-000000004119"), "reservation.read", "Consulter les reservations", "reservation"),
    (uuid.UUID("01920000-0000-7000-8000-000000004120"), "reservation.manage", "Enregistrer arrivee/depart, annuler une reservation", "reservation"),
    (uuid.UUID("01920000-0000-7000-8000-000000004121"), "folio.read", "Consulter les folios", "folio"),
    (uuid.UUID("01920000-0000-7000-8000-000000004122"), "folio.write", "Porter des charges, encaisser, clore un folio", "folio"),
    (uuid.UUID("01920000-0000-7000-8000-000000004123"), "order.read", "Consulter les commandes restaurant", "order"),
    (uuid.UUID("01920000-0000-7000-8000-000000004124"), "order.create", "Prendre une commande", "order"),
    (uuid.UUID("01920000-0000-7000-8000-000000004125"), "order.manage", "Envoyer, servir ou annuler une commande", "order"),
    (uuid.UUID("01920000-0000-7000-8000-000000004126"), "housekeeping.read", "Consulter les taches de nettoyage", "housekeeping"),
    (uuid.UUID("01920000-0000-7000-8000-000000004127"), "housekeeping.manage", "Creer, assigner, executer une tache de nettoyage", "housekeeping"),
    (uuid.UUID("01920000-0000-7000-8000-000000004128"), "maintenance.read", "Consulter les tickets de maintenance", "maintenance"),
    (uuid.UUID("01920000-0000-7000-8000-000000004129"), "maintenance.manage", "Creer, assigner, resoudre un ticket de maintenance", "maintenance"),
    (uuid.UUID("01920000-0000-7000-8000-000000004130"), "stock.movement", "Enregistrer un mouvement de stock", "stock"),
    (uuid.UUID("01920000-0000-7000-8000-000000004131"), "cash.session", "Ouvrir et fermer sa session de caisse", "cash"),
]
PRINT_REPRINT = PERMISSIONS[2][0]
RESERVATION_CREATE = PERMISSIONS[0][0]
ROOMS_READ = PERMISSIONS[3][0]
GUESTS_READ = PERMISSIONS[4][0]
GUESTS_WRITE = PERMISSIONS[5][0]
USERS_READ = PERMISSIONS[9][0]
USERS_WRITE = PERMISSIONS[10][0]
RESTAURANT_READ = PERMISSIONS[14][0]
RESERVATION_READ = PERMISSIONS[18][0]
RESERVATION_MANAGE = PERMISSIONS[19][0]
FOLIO_DISCOUNT = PERMISSIONS[1][0]
FOLIO_READ = PERMISSIONS[20][0]
FOLIO_WRITE = PERMISSIONS[21][0]
ORDER_READ = PERMISSIONS[22][0]
ORDER_CREATE = PERMISSIONS[23][0]
ORDER_MANAGE = PERMISSIONS[24][0]
HOUSEKEEPING_READ = PERMISSIONS[25][0]
HOUSEKEEPING_MANAGE = PERMISSIONS[26][0]
MAINTENANCE_READ = PERMISSIONS[27][0]
MAINTENANCE_MANAGE = PERMISSIONS[28][0]
STOCK_MOVEMENT = PERMISSIONS[29][0]
CASH_SESSION = PERMISSIONS[30][0]

ROLE_PERMISSIONS = [(ADMIN_ROLE, p[0]) for p in PERMISSIONS] + [
    (RECEPTION_ROLE, RESERVATION_CREATE),
    (RECEPTION_ROLE, ROOMS_READ),
    (RECEPTION_ROLE, GUESTS_READ),
    (RECEPTION_ROLE, GUESTS_WRITE),
    (RECEPTION_ROLE, RESERVATION_READ),
    (RECEPTION_ROLE, RESERVATION_MANAGE),
    (RECEPTION_ROLE, FOLIO_READ),
    # Porter des charges fait partie du metier de la reception, et le check-in
    # en porte deja une tout seul : la nuitee arrive sur l'ardoise au moment
    # de l'arrivee. Sans ce droit, un receptionniste produisait des ecritures
    # que le serveur lui refusait ensuite -- 403 a chaque tentative de
    # remontee, et une file bloquee derriere.
    #
    # `folio.discount` reste hors de sa portee : c'est la remise, pas la
    # charge, qui demande un second regard. La separation reception / caisse
    # se joue la, pas sur le fait de facturer une nuit.
    (RECEPTION_ROLE, FOLIO_WRITE),
    (RECEPTION_ROLE, PRINT_REPRINT),
    (MANAGER_ROLE, USERS_READ),
    (RESTAURANT_ROLE, RESTAURANT_READ),
    (RESTAURANT_ROLE, ORDER_READ),
    (RESTAURANT_ROLE, ORDER_CREATE),
    (RESTAURANT_ROLE, ORDER_MANAGE),
    (RESTAURANT_ROLE, PRINT_REPRINT),
    (CAISSE_ROLE, FOLIO_READ),
    (CAISSE_ROLE, FOLIO_WRITE),
    (CAISSE_ROLE, FOLIO_DISCOUNT),
    (CAISSE_ROLE, PRINT_REPRINT),
    (CAISSE_ROLE, CASH_SESSION),
    (HOUSEKEEPING_ROLE, HOUSEKEEPING_READ),
    (HOUSEKEEPING_ROLE, HOUSEKEEPING_MANAGE),
    (MAINTENANCE_ROLE, MAINTENANCE_READ),
    (MAINTENANCE_ROLE, MAINTENANCE_MANAGE),
]

DEMO_ADMIN = uuid.UUID("01920000-0000-7000-8000-000000050001")
DEMO_ADMIN_PASSWORD = "ChangeMe123!"

# Le receptionniste manquait ici alors que la tablette le connaissait depuis
# toujours, avec ce meme identifiant. Resultat : hors ligne il se connectait,
# en ligne le serveur refusait un compte qu'il n'avait jamais vu -- et
# l'application refuse a juste titre de se rabattre sur la base locale quand
# un serveur joignable dit non.
DEMO_RECEPTION = uuid.UUID("01920000-0000-7000-8000-000000050002")

# Le PIN sert aux releves de poste ; le mot de passe reste pour une premiere
# connexion et pour l'administration.
DEMO_PIN = "1234"

DEFAULT_PRINTER = uuid.UUID("01920000-0000-7000-8000-000000006001")
DOCUMENT_TYPES = [
    (uuid.UUID("01920000-0000-7000-8000-000000006101"), "KITCHEN_TICKET", "Ticket cuisine/bar", PrinterKind.THERMAL),
    (uuid.UUID("01920000-0000-7000-8000-000000006102"), "GUEST_INVOICE", "Facture client", PrinterKind.LASER),
    (uuid.UUID("01920000-0000-7000-8000-000000006103"), "MAINTENANCE_ORDER", "Bon de maintenance", PrinterKind.LASER),
    (uuid.UUID("01920000-0000-7000-8000-000000006104"), "SHIFT_REPORT", "Rapport de shift", PrinterKind.THERMAL),
]
PRINT_ROUTES = [
    (uuid.UUID("01920000-0000-7000-8000-000000006201"), DOCUMENT_TYPES[0][0]),
    (uuid.UUID("01920000-0000-7000-8000-000000006202"), DOCUMENT_TYPES[1][0]),
    (uuid.UUID("01920000-0000-7000-8000-000000006203"), DOCUMENT_TYPES[2][0]),
    (uuid.UUID("01920000-0000-7000-8000-000000006204"), DOCUMENT_TYPES[3][0]),
]


def room_id(number: str) -> uuid.UUID:
    return uuid.UUID(f"01920000-0000-7000-8000-00000003{number:0>4}")


async def seed(session: AsyncSession) -> None:
    async def upsert(model, rows: list[dict]) -> None:
        if not rows:
            return
        stmt = insert(model).values(rows)
        updatable = {
            c.name: stmt.excluded[c.name]
            for c in model.__table__.columns
            if c.name not in ("id", "created_at")
        }
        await session.execute(stmt.on_conflict_do_update(index_elements=["id"], set_=updatable))

    async def upsert_link(table, rows: list[dict], index_elements: list[str]) -> None:
        if not rows:
            return
        stmt = insert(table).values(rows)
        await session.execute(stmt.on_conflict_do_nothing(index_elements=index_elements))

    await upsert(Hotel, [{"id": HOTEL, "code": "ATR", "name": "Hotel Atrium", "city": "Abidjan", "country": "Cote d'Ivoire", "currency": "XOF"}])
    await upsert(Floor, [{"id": fid, "hotel_id": HOTEL, "code": code, "label": label, "sort_order": order} for fid, code, label, order in FLOORS])
    await upsert(RoomType, [{"id": tid, "hotel_id": HOTEL, "code": code, "label": label, "base_capacity": base, "max_capacity": maxi, "default_rate": rate, "sort_order": i} for i, (tid, code, label, base, maxi, rate) in enumerate(ROOM_TYPES)])
    await upsert(Room, [{"id": room_id(number), "hotel_id": HOTEL, "number": number, "room_type_id": type_id, "floor_id": floor_id} for number, type_id, floor_id in ROOMS])
    await upsert(Role, [{"id": rid, "code": code, "label": label, "is_system": True} for rid, code, label in ROLES])
    await upsert(Permission, [{"id": pid, "code": code, "label": label, "module": module} for pid, code, label, module in PERMISSIONS])
    await upsert_link(RolePermission, [{"role_id": role_id, "permission_id": perm_id} for role_id, perm_id in ROLE_PERMISSIONS], index_elements=["role_id", "permission_id"])
    await upsert(User, [
        {"id": DEMO_ADMIN, "hotel_id": HOTEL, "employee_code": "ADMIN01", "first_name": "Admin", "last_name": "Atrium", "email": "admin@atrium.local", "password_hash": hash_secret(DEMO_ADMIN_PASSWORD), "pin_hash": hash_secret(DEMO_PIN), "is_active": True, "must_change_password": False},
        # Meme jeu de colonnes que la ligne precedente : un `insert` a
        # plusieurs valeurs refuse des lignes de formes differentes.
        {"id": DEMO_RECEPTION, "hotel_id": HOTEL, "employee_code": "RECEP01", "first_name": "Awa", "last_name": "Traore", "email": "reception@atrium.local", "password_hash": hash_secret(DEMO_ADMIN_PASSWORD), "pin_hash": hash_secret(DEMO_PIN), "is_active": True, "must_change_password": False},
    ])
    await upsert_link(UserRole, [
        {"user_id": DEMO_ADMIN, "role_id": ADMIN_ROLE},
        {"user_id": DEMO_RECEPTION, "role_id": RECEPTION_ROLE},
    ], index_elements=["user_id", "role_id"])
    await upsert(Printer, [{"id": DEFAULT_PRINTER, "hotel_id": HOTEL, "logical_name": "IMP_DEFAUT_01", "label": "Imprimante par defaut", "kind": PrinterKind.LASER, "protocol": PrinterProtocol.IPP}])
    await upsert(DocumentType, [{"id": did, "hotel_id": HOTEL, "code": code, "label": label, "default_kind": kind} for did, code, label, kind in DOCUMENT_TYPES])
    await upsert(PrintRoute, [{"id": rid, "hotel_id": HOTEL, "document_type_id": doc_type_id, "printer_id": DEFAULT_PRINTER, "priority": 0} for rid, doc_type_id in PRINT_ROUTES])

    await session.commit()


async def main() -> None:
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        await seed(session)
    await engine.dispose()
    print(f"{len(ROOM_TYPES)} categories, {len(ROOMS)} chambres, {len(ROLES)} roles, {len(PERMISSIONS)} permissions.")
    print(f"Comptes demo : ADMIN01 et RECEP01 — mot de passe {DEMO_ADMIN_PASSWORD}, code PIN {DEMO_PIN}.")


if __name__ == "__main__":
    asyncio.run(main())
