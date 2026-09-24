/// Les depots, exposes a l'arbre de widgets.
///
/// Les ecrans ne connaissent que ces objets : jamais la base directement,
/// jamais le reseau. C'est cette frontiere qui rendra la synchronisation
/// possible plus tard sans toucher a un seul widget.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local/database_provider.dart';
import 'guest_repository.dart';
import 'outbox.dart';
import 'reservation_repository.dart';

final guestRepositoryProvider = Provider<GuestRepository>(
  (ref) => GuestRepository(ref.watch(databaseProvider)),
);

final reservationRepositoryProvider = Provider<ReservationRepository>(
  (ref) => ReservationRepository(ref.watch(databaseProvider)),
);

/// Nombre d'ecritures qui attendent de remonter au serveur.
final pendingWritesProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchPendingCount(),
);
