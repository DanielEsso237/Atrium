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
import 'folio_repository.dart';
import 'guest_repository.dart';
import 'outbox.dart';
import 'reservation_repository.dart';
import 'sync_repository.dart';

final guestRepositoryProvider = Provider<GuestRepository>(
  (ref) => GuestRepository(ref.watch(databaseProvider)),
);

final folioRepositoryProvider = Provider<FolioRepository>(
  (ref) => FolioRepository(ref.watch(databaseProvider)),
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
