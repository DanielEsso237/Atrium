/// Les depots, exposes a l'arbre de widgets.
///
/// Les ecrans ne connaissent que ces objets : jamais la base directement,
/// jamais le reseau. C'est cette frontiere qui rendra la synchronisation
/// possible plus tard sans toucher a un seul widget.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local/database.dart';
import '../local/database_provider.dart';
import '../local/queries/rooms_queries.dart';
import '../local/files/photo_files.dart';
import '../remote/file_uploader.dart';
import '../remote/outbox_sender.dart';
import '../remote/remote_providers.dart';
import 'agent_repository.dart';
import 'cash_repository.dart';
import 'descente.dart';
import 'folio_repository.dart';
import 'guest_repository.dart';
import 'hotel_repository.dart';
import 'housekeeping_repository.dart';
import 'id_photo_repository.dart';
import 'invoice_repository.dart';
import 'maintenance_repository.dart';
import 'order_repository.dart';
import 'outbox.dart';
import 'outlet_repository.dart';
import 'reservation_repository.dart';
import 'role_repository.dart';
import 'settings_repository.dart';
import 'stock_repository.dart';
import 'sync_repository.dart';

final outletRepositoryProvider = Provider<OutletRepository>(
  (ref) => OutletRepository(ref.watch(databaseProvider)),
);

final agentRepositoryProvider = Provider<AgentRepository>(
  (ref) => AgentRepository(ref.watch(databaseProvider)),
);

final roleRepositoryProvider = Provider<RoleRepository>(
  (ref) => RoleRepository(ref.watch(databaseProvider)),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

/// Heure de depart et prix de l'heure supplementaire, en flux continu.
final stayRulesProvider = StreamProvider<StayRules>(
  (ref) => ref.watch(settingsRepositoryProvider).watchStayRules(),
);

final guestRepositoryProvider = Provider<GuestRepository>(
  (ref) => GuestRepository(ref.watch(databaseProvider)),
);

final idPhotoRepositoryProvider = Provider<IdPhotoRepository>(
  (ref) => IdPhotoRepository(ref.watch(databaseProvider), platformPhotoFiles()),
);

final folioRepositoryProvider = Provider<FolioRepository>(
  (ref) => FolioRepository(ref.watch(databaseProvider)),
);

final housekeepingRepositoryProvider = Provider<HousekeepingRepository>(
  (ref) => HousekeepingRepository(ref.watch(databaseProvider)),
);

/// Les chambres a faire aujourd'hui, en direct.
final cleaningJobsProvider = StreamProvider<List<CleaningJob>>(
  (ref) => ref.watch(housekeepingRepositoryProvider).watchJobs(),
);

final vacantRoomsForCleaningProvider = StreamProvider<List<RoomBoardEntry>>(
  (ref) => ref.watch(housekeepingRepositoryProvider).watchVacantRooms(),
);

final cashRepositoryProvider = Provider<CashRepository>(
  (ref) => CashRepository(ref.watch(databaseProvider)),
);

/// La caisse ouverte de l'agent connecte, avec son attendu en direct.
final currentCashProvider = StreamProvider.family<CashView?, String>(
  (ref, userId) => ref.watch(cashRepositoryProvider).watchCurrent(userId),
);

final hotelRepositoryProvider = Provider<HotelRepository>(
  (ref) => HotelRepository(ref.watch(databaseProvider)),
);

/// L'hotel de la tablette : nom, coordonnees et logo des factures.
final hotelProvider = StreamProvider<HotelRow?>(
  (ref) => ref.watch(hotelRepositoryProvider).watch(),
);

final invoiceRepositoryProvider = Provider<InvoiceRepository>(
  (ref) => InvoiceRepository(ref.watch(databaseProvider)),
);

/// La facture d'une ardoise, en direct : elle change quand le serveur
/// attribue le numero legal.
final invoiceForFolioProvider = StreamProvider.family<InvoiceView?, String>(
  (ref, folioId) => ref.watch(invoiceRepositoryProvider).watchForFolio(folioId),
);

final orderRepositoryProvider = Provider<OrderRepository>(
  (ref) => OrderRepository(ref.watch(databaseProvider)),
);

/// Les points de vente actifs, dans l'ordre de leurs onglets.
final outletsProvider = StreamProvider.family<List<OutletRow>, String?>(
  (ref, agentId) =>
      ref.watch(orderRepositoryProvider).watchOutlets(agentId: agentId),
);

/// La carte d'un point de vente, en direct.
final menuForOutletProvider = StreamProvider.family<List<MenuEntry>, String>(
  (ref, outletId) => ref.watch(orderRepositoryProvider).watchMenu(outletId),
);

/// Les chambres a qui l'on peut porter une consommation.
final chargeableRoomsProvider = StreamProvider<List<ChargeableRoom>>(
  (ref) => ref.watch(orderRepositoryProvider).watchChargeableRooms(),
);

final stockRepositoryProvider = Provider<StockRepository>(
  (ref) => StockRepository(ref.watch(databaseProvider)),
);

/// Les magasins : l'economat d'abord.
final stockPlacesProvider = StreamProvider<List<StockPlace>>(
  (ref) => ref.watch(stockRepositoryProvider).watchPlaces(),
);

/// Les produits d'un magasin et leur quantite. A l'economat, tous les
/// produits, meme a zero : on y voit ce qu'il faut commander.
final stockLinesProvider =
    StreamProvider.family<List<StockLine>, ({String placeId, bool all})>(
      (ref, cle) => ref
          .watch(stockRepositoryProvider)
          .watchLines(cle.placeId, allProducts: cle.all),
    );

final stockProductsProvider = StreamProvider<List<StockProduct>>(
  (ref) => ref.watch(stockRepositoryProvider).watchProducts(),
);

/// Les transferts qui attendent une validation.
final pendingTransfersProvider = StreamProvider<List<PendingTransfer>>(
  (ref) => ref.watch(stockRepositoryProvider).watchPendingTransfers(),
);

final reservationRepositoryProvider = Provider<ReservationRepository>(
  (ref) => ReservationRepository(ref.watch(databaseProvider)),
);

/// Nombre d'ecritures qui attendent de remonter au serveur.
final pendingWritesProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchPendingCount(),
);

/// Descente des donnees du serveur vers Drift.
final syncRepositoryProvider = Provider<SyncRepository>(
  (ref) => SyncRepository(
    ref.watch(databaseProvider),
    ref.watch(catalogApiProvider),
  ),
);

/// Descente des donnees metier : clients, reservations, ardoises.
///
/// Distincte de `syncRepositoryProvider`, qui ne rapatrie que le referentiel
/// des chambres. Les deux sont appelees ensemble par le moteur.
final descenteProvider = Provider<Descente>(
  (ref) => Descente(
    ref.watch(databaseProvider),
    ref.watch(catalogApiProvider),
    ref.watch(syncRepositoryProvider),
  ),
);

/// Montee des ecritures locales vers le serveur.
final outboxSenderProvider = Provider<OutboxSender>(
  (ref) => OutboxSender(
    db: ref.watch(databaseProvider),
    api: ref.watch(apiClientProvider),
  ),
);

/// Montee des photos, sur leur propre file : jamais devant la file d'envoi.
final fileUploaderProvider = Provider<FileUploader>(
  (ref) => FileUploader(
    db: ref.watch(databaseProvider),
    api: ref.watch(apiClientProvider),
    files: platformPhotoFiles(),
  ),
);

/// Les photos qui attendent de remonter.
///
/// A part de `pendingWritesProvider` : une photo en attente n'est pas une
/// ecriture bloquee, et ne doit ni allumer le bandeau ni relancer la file.
final pendingUploadsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return db
      .customSelect(
        "SELECT COUNT(*) AS n FROM file_uploads WHERE status = 'PENDING'",
        readsFrom: {db.fileUploads},
      )
      .watchSingle()
      .map((r) => r.read<int>('n'));
});

final maintenanceRepositoryProvider = Provider<MaintenanceRepository>(
  (ref) => MaintenanceRepository(ref.watch(databaseProvider)),
);

final ticketsProvider = StreamProvider<List<TicketSummary>>(
  (ref) => ref.watch(maintenanceRepositoryProvider).watchTickets(),
);
