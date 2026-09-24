/// Enumerations metier de la base locale.
///
/// Elles sont le miroir exact de `backend/app/models/enums.py`. Chaque valeur
/// est stockee sous forme de texte (`textEnum`), avec la meme chaine des deux
/// cotes : c'est ce qui permet a la synchronisation de recopier la valeur telle
/// quelle, sans table de correspondance ni conversion.
///
/// Consequence importante : ne jamais renommer une valeur existante, et ne
/// jamais se fier a l'ordre de declaration. Ajouter une valeur est sans risque,
/// en renommer une casse toutes les lignes deja enregistrees.
library;

// --- Chambres ---------------------------------------------------------------

enum OccupancyStatus { VACANT, RESERVED, OCCUPIED }

enum HousekeepingStatus { CLEAN, DIRTY, IN_PROGRESS, INSPECTED }

enum TaxMode { PERCENT, PER_NIGHT, PER_PERSON_NIGHT, FIXED }

/// Pastille affichee sur le plan de l'hotel (ecran 5.2 du cahier des charges).
///
/// Cette valeur n'est pas stockee : elle se calcule a partir des trois axes
/// independants d'une chambre. Voir `Room.displayStatus`.
enum RoomDisplayStatus { AVAILABLE, OCCUPIED, RESERVED, CLEANING, MAINTENANCE }

// --- Reservations -----------------------------------------------------------

enum ReservationStatus {
  PENDING,
  CONFIRMED,
  CHECKED_IN,
  CHECKED_OUT,
  CANCELLED,
  NO_SHOW,
}

enum ReservationSource { DIRECT, PHONE, WALK_IN, OTA, CORPORATE, EMAIL }

enum SignatureKind { CHECK_IN, CHECK_OUT, INVOICE, OTHER }

// --- Facturation ------------------------------------------------------------

enum FolioType { GUEST, MASTER, WALK_IN, TABLE }

enum FolioStatus { OPEN, CLOSED, SETTLED }

enum ChargeCategory {
  ROOM,
  FNB,
  MINIBAR,
  SPA,
  LAUNDRY,
  TELEPHONE,
  TAX,
  DISCOUNT,
  DEPOSIT,
  MISC,
}

enum InvoiceStatus { DRAFT, ISSUED, PAID, CANCELLED }

enum PaymentMethod { CASH, CARD, TRANSFER, MOBILE_MONEY, CITY_LEDGER, VOUCHER }

enum CashSessionStatus { OPEN, CLOSED }

// --- Restauration -----------------------------------------------------------

/// Mode de service, et lui seul : le *lieu* est porte par `orders.outletId`.
///
/// L'ancienne valeur `POOL` etait un lieu, pas un mode -- la piscine etait
/// donc representable de deux facons, ce qui garantit de retrouver les deux
/// dans les donnees. Une consommation au bord du bassin est desormais
/// ON_SITE / outlet POOL.
enum OrderType { ON_SITE, ROOM_SERVICE, TAKEAWAY, DELIVERY }

enum OrderStatus { DRAFT, SENT, IN_PREP, READY, SERVED, CANCELLED }

enum TableStatus { FREE, OCCUPIED, RESERVED }

// --- Housekeeping et maintenance --------------------------------------------

enum HousekeepingTaskType {
  DEPARTURE,
  STAYOVER,
  REFRESH,
  DEEP_CLEAN,
  INSPECTION,
}

enum TaskStatus { PENDING, ASSIGNED, IN_PROGRESS, DONE, INSPECTED, CANCELLED }

enum Priority { LOW, NORMAL, HIGH, URGENT }

enum TicketStatus { OPEN, ASSIGNED, IN_PROGRESS, RESOLVED, CLOSED, CANCELLED }

// --- Stocks -----------------------------------------------------------------

enum StockMovementType { IN, OUT, TRANSFER, ADJUSTMENT, LOSS, RETURN }

enum InventoryStatus { DRAFT, COUNTING, CLOSED }

// --- Impression -------------------------------------------------------------

enum PrinterKind { LASER, THERMAL }

enum PrinterProtocol { IPP, LPD, ESCPOS_NET, ESCPOS_USB, RAW9100 }

enum PrintJobStatus { QUEUED, SENT, PRINTED, FAILED, CANCELLED }

enum TemplateFormat { ESCPOS, HTML, PDF }

// --- Synchronisation --------------------------------------------------------

enum SyncOp { INSERT, UPDATE, DELETE }

enum SyncState { synced, pending, conflict }

enum OutboxStatus { PENDING, SENDING, ACKED, FAILED }

enum UploadState { PENDING, UPLOADING, UPLOADED, FAILED }

// --- Divers -----------------------------------------------------------------

enum SettingScope { GLOBAL, DEVICE, USER }

enum BusinessDayStatus { OPEN, CLOSED }

enum IdDocumentType {
  ID_CARD,
  PASSPORT,
  DRIVING_LICENSE,
  RESIDENCE_PERMIT,
  OTHER,
}
