/// Les depots, exposes a l'arbre de widgets.
///
/// Les ecrans ne connaissent que ces objets : jamais la base directement,
/// jamais le reseau. C'est cette frontiere qui rendra la synchronisation
/// possible plus tard sans toucher a un seul widget.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local/database_provider.dart';
import '../remote/outbox_sender.dart';
import '../remote/remote_providers.dart';
import 'cash_repository.dart';
import 'folio_repository.dart';
import 'guest_repository.dart';
import 'housekeeping_repository.dart';
import 'invoice_repository.dart';
import 'outbox.dart';
import 'reservation_repository.dart';
import 'sync_repository.dart';

final guestRepositoryProvider = Provider<GuestRepository>(
  (ref) => GuestRepository(ref.watch(databaseProvider)),
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

final cashRepositoryProvider = Provider<CashRepository>(
  (ref) => CashRepository(ref.watch(databaseProvider)),
);

/// La caisse ouverte de l'agent connecte, avec son attendu en direct.
final currentCashProvider = StreamProvider.family<CashView?, String>(
  (ref, userId) => ref.watch(cashRepositoryProvider).watchCurrent(userId),
);

final invoiceRepositoryProvider = Provider<InvoiceRepository>(
  (ref) => InvoiceRepository(ref.watch(databaseProvider)),
);

/// La facture d'une ardoise, en direct : elle change quand le serveur
/// attribue le numero legal.
final invoiceForFolioProvider = StreamProvider.family<InvoiceView?, String>(
  (ref, folioId) =>
      ref.watch(invoiceRepositoryProvider).watchForFolio(folioId),
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

/// Montee des ecritures locales vers le serveur.
final outboxSenderProvider = Provider<OutboxSender>(
  (ref) => OutboxSender(
    db: ref.watch(databaseProvider),
    api: ref.watch(apiClientProvider),
  ),
);
