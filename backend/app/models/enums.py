"""Enumerations metier.

Elles sont mappees en VARCHAR + CHECK (`native_enum=False`) et non en type ENUM
PostgreSQL natif, pour deux raisons :

1. ajouter une valeur a un ENUM natif est une migration bloquante penible ;
2. SQLite -- donc Drift, cote tablette -- ne connait pas les ENUM. Un VARCHAR
   contraint donne exactement le meme schema logique des deux cotes, ce qui est
   la condition pour que la synchronisation reste un simple mapping 1:1.
"""

from __future__ import annotations

import enum


class StrEnum(str, enum.Enum):
    def __str__(self) -> str:
        return self.value


# --- Chambres ---------------------------------------------------------------


class OccupancyStatus(StrEnum):
    VACANT = "VACANT"
    RESERVED = "RESERVED"
    OCCUPIED = "OCCUPIED"


class HousekeepingStatus(StrEnum):
    CLEAN = "CLEAN"
    DIRTY = "DIRTY"
    IN_PROGRESS = "IN_PROGRESS"
    INSPECTED = "INSPECTED"


class TaxMode(StrEnum):
    PERCENT = "PERCENT"
    PER_NIGHT = "PER_NIGHT"
    PER_PERSON_NIGHT = "PER_PERSON_NIGHT"
    FIXED = "FIXED"


# --- Reservations -----------------------------------------------------------


class ReservationStatus(StrEnum):
    PENDING = "PENDING"
    CONFIRMED = "CONFIRMED"
    CHECKED_IN = "CHECKED_IN"
    CHECKED_OUT = "CHECKED_OUT"
    CANCELLED = "CANCELLED"
    NO_SHOW = "NO_SHOW"


class ReservationSource(StrEnum):
    DIRECT = "DIRECT"
    PHONE = "PHONE"
    WALK_IN = "WALK_IN"
    OTA = "OTA"
    CORPORATE = "CORPORATE"
    EMAIL = "EMAIL"


class SignatureKind(StrEnum):
    CHECK_IN = "CHECK_IN"
    CHECK_OUT = "CHECK_OUT"
    INVOICE = "INVOICE"
    OTHER = "OTHER"


# --- Facturation ------------------------------------------------------------


class FolioType(StrEnum):
    GUEST = "GUEST"
    MASTER = "MASTER"
    WALK_IN = "WALK_IN"
    TABLE = "TABLE"


class FolioStatus(StrEnum):
    OPEN = "OPEN"
    CLOSED = "CLOSED"
    SETTLED = "SETTLED"


class ChargeCategory(StrEnum):
    ROOM = "ROOM"
    FNB = "FNB"
    MINIBAR = "MINIBAR"
    SPA = "SPA"
    LAUNDRY = "LAUNDRY"
    TELEPHONE = "TELEPHONE"
    TAX = "TAX"
    DISCOUNT = "DISCOUNT"
    DEPOSIT = "DEPOSIT"
    MISC = "MISC"


class InvoiceStatus(StrEnum):
    DRAFT = "DRAFT"
    ISSUED = "ISSUED"
    PAID = "PAID"
    CANCELLED = "CANCELLED"


class PaymentMethod(StrEnum):
    CASH = "CASH"
    CARD = "CARD"
    TRANSFER = "TRANSFER"
    MOBILE_MONEY = "MOBILE_MONEY"
    CITY_LEDGER = "CITY_LEDGER"
    VOUCHER = "VOUCHER"


class CashSessionStatus(StrEnum):
    OPEN = "OPEN"
    CLOSED = "CLOSED"


# --- Restauration -----------------------------------------------------------


class OrderType(StrEnum):
    """Mode de service, et lui seul.

    Le *lieu* est porte par `orders.outlet_id` (restaurant, bar, piscine,
    boite de nuit). Melanger les deux -- l'ancienne valeur `POOL` etait un
    lieu -- rendait la piscine representable de deux facons, ce qui garantit
    de retrouver les deux dans les donnees.

    Une consommation au bord du bassin est donc ON_SITE / outlet POOL, et une
    commande de la boite de nuit montee en chambre devient ROOM_SERVICE /
    outlet NIGHTCLUB -- combinaison inexprimable auparavant.
    """

    ON_SITE = "ON_SITE"
    ROOM_SERVICE = "ROOM_SERVICE"
    TAKEAWAY = "TAKEAWAY"
    DELIVERY = "DELIVERY"


class OrderStatus(StrEnum):
    DRAFT = "DRAFT"
    SENT = "SENT"
    IN_PREP = "IN_PREP"
    READY = "READY"
    SERVED = "SERVED"
    CANCELLED = "CANCELLED"


class TableStatus(StrEnum):
    FREE = "FREE"
    OCCUPIED = "OCCUPIED"
    RESERVED = "RESERVED"


# --- Housekeeping / maintenance ---------------------------------------------


class HousekeepingTaskType(StrEnum):
    DEPARTURE = "DEPARTURE"
    STAYOVER = "STAYOVER"
    REFRESH = "REFRESH"
    DEEP_CLEAN = "DEEP_CLEAN"
    INSPECTION = "INSPECTION"


class TaskStatus(StrEnum):
    PENDING = "PENDING"
    ASSIGNED = "ASSIGNED"
    IN_PROGRESS = "IN_PROGRESS"
    DONE = "DONE"
    INSPECTED = "INSPECTED"
    CANCELLED = "CANCELLED"


class Priority(StrEnum):
    LOW = "LOW"
    NORMAL = "NORMAL"
    HIGH = "HIGH"
    URGENT = "URGENT"


class TicketStatus(StrEnum):
    OPEN = "OPEN"
    ASSIGNED = "ASSIGNED"
    IN_PROGRESS = "IN_PROGRESS"
    RESOLVED = "RESOLVED"
    CLOSED = "CLOSED"
    CANCELLED = "CANCELLED"


# --- Stocks -----------------------------------------------------------------


class StockMovementType(StrEnum):
    IN = "IN"
    OUT = "OUT"
    TRANSFER = "TRANSFER"
    ADJUSTMENT = "ADJUSTMENT"
    LOSS = "LOSS"
    RETURN = "RETURN"


class InventoryStatus(StrEnum):
    DRAFT = "DRAFT"
    COUNTING = "COUNTING"
    CLOSED = "CLOSED"


# --- Impression -------------------------------------------------------------


class PrinterKind(StrEnum):
    LASER = "LASER"
    THERMAL = "THERMAL"


class PrinterProtocol(StrEnum):
    IPP = "IPP"
    LPD = "LPD"
    ESCPOS_NET = "ESCPOS_NET"
    ESCPOS_USB = "ESCPOS_USB"
    RAW9100 = "RAW9100"


class PrintJobStatus(StrEnum):
    QUEUED = "QUEUED"
    SENT = "SENT"
    PRINTED = "PRINTED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"


class TemplateFormat(StrEnum):
    ESCPOS = "ESCPOS"
    HTML = "HTML"
    PDF = "PDF"


# --- Synchronisation --------------------------------------------------------


class SyncOp(StrEnum):
    INSERT = "INSERT"
    UPDATE = "UPDATE"
    DELETE = "DELETE"


class ConflictResolution(StrEnum):
    SERVER_WINS = "SERVER_WINS"
    CLIENT_WINS = "CLIENT_WINS"
    MERGED = "MERGED"
    MANUAL = "MANUAL"
    PENDING = "PENDING"


class UploadState(StrEnum):
    PENDING = "PENDING"
    UPLOADING = "UPLOADING"
    UPLOADED = "UPLOADED"
    FAILED = "FAILED"


# --- Divers -----------------------------------------------------------------


class SettingScope(StrEnum):
    GLOBAL = "GLOBAL"
    DEVICE = "DEVICE"
    USER = "USER"


class BusinessDayStatus(StrEnum):
    OPEN = "OPEN"
    CLOSED = "CLOSED"


class IdDocumentType(StrEnum):
    ID_CARD = "ID_CARD"
    PASSPORT = "PASSPORT"
    DRIVING_LICENSE = "DRIVING_LICENSE"
    RESIDENCE_PERMIT = "RESIDENCE_PERMIT"
    OTHER = "OTHER"
