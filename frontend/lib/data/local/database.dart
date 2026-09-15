/// Base de donnees locale d'Atrium.
///
/// SQLite via Drift, sur chaque tablette. C'est elle qui rend l'application
/// utilisable pendant une coupure Wi-Fi (exigence 6.3 du cahier des charges) :
/// toutes les lectures et toutes les ecritures passent par ici, le reseau
/// n'etant qu'un mecanisme d'echange en arriere-plan.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'enums.dart';
import 'tables/admin.dart';
import 'tables/billing.dart';
import 'tables/core.dart';
import 'tables/guests.dart';
import 'tables/operations.dart';
import 'tables/printing.dart';
import 'tables/reservations.dart';
import 'tables/restaurant.dart';
import 'tables/rooms.dart';
import 'tables/stock.dart';
import 'tables/sync.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    // Socle
    Hotels,
    Roles,
    Permissions,
    RolePermissions,
    Users,
    UserRoles,
    Devices,
    // Hebergement
    Floors,
    RoomTypes,
    Rooms,
    RatePlans,
    RatePlanPrices,
    Taxes,
    // Clients
    Companies,
    Guests,
    GuestDocuments,
    // Reservations
    Reservations,
    ReservationRooms,
    StayNights,
    ReservationGuests,
    Signatures,
    // Facturation
    Folios,
    FolioItems,
    Invoices,
    InvoiceLines,
    CashSessions,
    Payments,
    // Restauration
    Outlets,
    PrepStations,
    RestaurantTables,
    MenuCategories,
    MenuItems,
    MenuItemOptions,
    Orders,
    OrderItems,
    OrderItemOptions,
    // Housekeeping et maintenance
    HousekeepingTasks,
    HousekeepingTaskItems,
    AmenityConsumptions,
    Equipments,
    MaintenanceTickets,
    MaintenanceInterventions,
    Attachments,
    // Stocks
    Suppliers,
    ProductCategories,
    Products,
    StockLocations,
    StockLevels,
    StockMovements,
    Inventories,
    InventoryLines,
    // Impression
    Printers,
    DocumentTypes,
    PrintRoutes,
    DocumentTemplates,
    PrintJobs,
    // Administration
    Settings,
    BusinessDays,
    Notifications,
    // Synchronisation (local uniquement)
    OutboxEntries,
    SyncCursors,
    SyncStatuses,
    FileUploads,
  ],
)
class AtriumDatabase extends _$AtriumDatabase {
  AtriumDatabase([QueryExecutor? executor])
      : super(executor ?? _openConnection());

  /// Utilise par les tests : base en memoire, jetee a la fin.
  AtriumDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 1;

  /// Horodatages stockes en texte ISO-8601 plutot qu'en entier Unix.
  ///
  /// Moins compact, mais lisible quand on ouvre la base d'une tablette avec un
  /// outil SQLite pour comprendre un incident sur site -- et le fuseau n'est
  /// pas perdu en route.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
        },
        beforeOpen: (details) async {
          // Integrite referentielle : desactivee par defaut dans SQLite, il
          // faut la redemander a chaque ouverture de connexion.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// Applique un lot venu du serveur en differant le controle des cles
  /// etrangeres jusqu'au commit.
  ///
  /// C'est ce qui rend les contraintes tenables en synchronisation. Sans cela,
  /// un lot devrait arriver dans un ordre strictement topologique : la
  /// reservation avant ses chambres, la commande avant ses lignes. Avec
  /// `defer_foreign_keys`, l'ordre a l'interieur d'un lot n'a plus
  /// d'importance -- seule compte la coherence du lot une fois complet.
  ///
  /// Le controle a lieu quand meme, au commit : un lot qui reference un parent
  /// absent est rejete en bloc, ce qui est exactement le comportement voulu.
  /// Le pragma se reinitialise de lui-meme a la fin de chaque transaction.
  Future<T> syncTransaction<T>(Future<T> Function() action) {
    return transaction(() async {
      await customStatement('PRAGMA defer_foreign_keys = ON');
      return action();
    });
  }

  /// Index metier, au-dela de ceux que Drift cree pour les cles primaires.
  ///
  /// Ils visent les ecrans qui doivent rester instantanes sur une tablette :
  /// le plan des chambres, le planning des arrivees du jour, les tickets
  /// ouverts en cuisine, la file d'impression.
  Future<void> _createIndexes() async {
    const statements = [
      // Plan de l'hotel et etats de chambres (ecran 5.2)
      'CREATE INDEX IF NOT EXISTS ix_rooms_occupancy ON rooms(occupancy_status)',
      'CREATE INDEX IF NOT EXISTS ix_rooms_housekeeping ON rooms(housekeeping_status)',
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_rooms_number ON rooms(hotel_id, number)',

      // Arrivees et departs du jour
      'CREATE INDEX IF NOT EXISTS ix_reservations_dates ON reservations(arrival_date, departure_date)',
      'CREATE INDEX IF NOT EXISTS ix_reservations_status ON reservations(status)',
      'CREATE INDEX IF NOT EXISTS ix_resrooms_room_dates ON reservation_rooms(room_id, arrival_date, departure_date)',
      'CREATE INDEX IF NOT EXISTS ix_resrooms_reservation ON reservation_rooms(reservation_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_stay_nights ON stay_nights(reservation_room_id, business_date)',
      'CREATE INDEX IF NOT EXISTS ix_stay_nights_date ON stay_nights(business_date)',

      // Recherche client
      'CREATE INDEX IF NOT EXISTS ix_guests_last_name ON guests(last_name)',
      'CREATE INDEX IF NOT EXISTS ix_guests_phone ON guests(phone)',
      'CREATE INDEX IF NOT EXISTS ix_guests_doc ON guests(id_document_number)',

      // Facturation
      'CREATE INDEX IF NOT EXISTS ix_folio_items_folio ON folio_items(folio_id)',
      'CREATE INDEX IF NOT EXISTS ix_folio_items_date ON folio_items(business_date)',
      'CREATE INDEX IF NOT EXISTS ix_payments_date ON payments(business_date)',

      // Restauration : ecrans cuisine et bar (F3.4)
      'CREATE INDEX IF NOT EXISTS ix_orders_status ON orders(status)',
      'CREATE INDEX IF NOT EXISTS ix_order_items_station ON order_items(prep_station_id, status)',
      'CREATE INDEX IF NOT EXISTS ix_order_items_order ON order_items(order_id)',

      // Housekeeping et maintenance
      'CREATE INDEX IF NOT EXISTS ix_hk_tasks_date_status ON housekeeping_tasks(business_date, status)',
      'CREATE INDEX IF NOT EXISTS ix_hk_tasks_assignee ON housekeeping_tasks(assigned_to)',
      'CREATE INDEX IF NOT EXISTS ix_tickets_status ON maintenance_tickets(status, priority)',

      // File d'impression (regle R2)
      'CREATE INDEX IF NOT EXISTS ix_print_jobs_status ON print_jobs(status, created_at)',

      // Synchronisation
      'CREATE INDEX IF NOT EXISTS ix_outbox_status ON outbox_entries(status, id)',
      'CREATE INDEX IF NOT EXISTS ix_uploads_status ON file_uploads(status)',
    ];

    for (final statement in statements) {
      await customStatement(statement);
    }
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'atrium.sqlite'));

    // package:sqlite3 3.x embarque lui-meme la bibliotheque native via les
    // hooks de build Dart : toutes les tablettes du parc utilisent la meme
    // version de SQLite, quel que soit leur constructeur ou leur version
    // d'Android. C'est ce qui remplace l'ancien paquet sqlite3_flutter_libs.
    sqlite3.tempDirectory = (await getTemporaryDirectory()).path;

    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        // WAL : indispensable en kiosque. Une tablette debranchee ou eteinte
        // brutalement ne doit pas corrompre la base, et la lecture reste
        // possible pendant qu'une ecriture est en cours.
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA foreign_keys = ON');
        db.execute('PRAGMA busy_timeout = 5000');
      },
    );
  });
}
