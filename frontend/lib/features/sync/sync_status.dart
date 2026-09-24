/// L'etat du dernier rafraichissement, et de quoi en declencher un.
///
/// Volontairement separe de la session : se connecter et rapatrier des
/// donnees sont deux choses differentes, qui echouent pour des raisons
/// differentes. Un serveur qui refuse le mot de passe n'est pas un serveur
/// qui ne repond pas.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/outbox_sender.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/sync_repository.dart';

class SyncUiState {
  const SyncUiState({this.running = false, this.last, this.at, this.push});

  /// Un rafraichissement est en cours.
  final bool running;

  /// Ce qu'a donne le dernier, ou `null` si aucun n'a encore eu lieu.
  final SyncOutcome? last;

  /// Quand il a eu lieu.
  final DateTime? at;

  /// Ce qu'a donne la remontee des ecritures locales.
  final DrainReport? push;

  bool get neverRan => last == null;
  bool get isOffline => last?.offline ?? false;

  /// Une ecriture est refusee par le serveur et bloque la file derriere elle.
  ///
  /// C'est le seul etat de synchronisation qui merite d'interrompre un
  /// receptionniste : hors ligne se resout tout seul, un blocage non.
  bool get isBlocked => push?.arret == DrainStop.bloque;
}

class SyncNotifier extends Notifier<SyncUiState> {
  @override
  SyncUiState build() => const SyncUiState();

  /// Remonte les ecritures locales, puis rapatrie le referentiel.
  ///
  /// **Cet ordre n'est pas negociable.** La descente ecrase les lignes locales
  /// avec celles du serveur ; tant qu'un check-in n'est pas remonte, le
  /// serveur croit la chambre libre et la rendrait libre sur la tablette. On
  /// pousse donc d'abord. `pullRooms` sait deja epargner les lignes en
  /// attente, mais cette protection ne devrait servir qu'aux cas ou la
  /// remontee vient d'echouer -- pas a tous les rafraichissements.
  ///
  /// N'echoue jamais bruyamment : si le serveur ne repond pas, l'ecran garde
  /// ce qu'il affichait. C'est tout l'interet d'ecrire dans Drift plutot que
  /// de servir directement le reseau aux widgets.
  Future<SyncOutcome> refresh() async {
    if (state.running) return const SyncOutcome.offline();
    state = SyncUiState(
      running: true,
      last: state.last,
      at: state.at,
      push: state.push,
    );

    final push = await ref.read(outboxSenderProvider).drain();
    final outcome = await ref.read(syncRepositoryProvider).pullRooms();

    state = SyncUiState(last: outcome, at: DateTime.now(), push: push);
    return outcome;
  }
}

final syncProvider = NotifierProvider<SyncNotifier, SyncUiState>(
  SyncNotifier.new,
);
