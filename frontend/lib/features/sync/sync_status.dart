/// L'etat des echanges avec le serveur, et de quoi en declencher.
///
/// Volontairement separe de la session : se connecter et echanger des donnees
/// sont deux choses differentes, qui echouent pour des raisons differentes. Un
/// serveur qui refuse le mot de passe n'est pas un serveur qui ne repond pas.
///
/// C'est ici, et non dans la session, que vit la reponse a « suis-je en
/// ligne ? ». La session ne le sait qu'au moment de la connexion ; un agent
/// devait donc se deconnecter et se reconnecter pour que l'application
/// remarque le retour du serveur. Le dernier echange, lui, le sait a chaque
/// fois.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/outbox_sender.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/sync_repository.dart';

class SyncUiState {
  const SyncUiState({
    this.running = false,
    this.last,
    this.at,
    this.push,
    this.joignable,
  });

  /// Un echange est en cours.
  final bool running;

  /// Ce qu'a donne la derniere descente, ou `null` si aucune n'a eu lieu.
  final SyncOutcome? last;

  /// Quand le dernier echange a eu lieu.
  final DateTime? at;

  /// Ce qu'a donne la derniere remontee des ecritures locales.
  final DrainReport? push;

  /// Le serveur repondait-il au dernier echange ?
  ///
  /// `null` tant qu'aucun echange n'a rien appris — file vide et pas de
  /// descente. L'appelant retombe alors sur ce que disait la connexion.
  final bool? joignable;

  bool get neverRan => last == null;
  bool get isOffline => joignable == false;

  /// Une ecriture est refusee par le serveur et bloque la file derriere elle.
  ///
  /// C'est le seul etat de synchronisation qui merite d'interrompre un
  /// receptionniste : hors ligne se resout tout seul, un blocage non.
  bool get isBlocked => push?.arret == DrainStop.bloque;

  /// Le serveur a repondu, mais la session ne vaut plus rien.
  bool get sessionExpired => push?.arret == DrainStop.sessionInvalide;

  SyncUiState copyWith({
    bool? running,
    SyncOutcome? last,
    DateTime? at,
    DrainReport? push,
    bool? joignable,
  }) {
    return SyncUiState(
      running: running ?? this.running,
      last: last ?? this.last,
      at: at ?? this.at,
      push: push ?? this.push,
      joignable: joignable ?? this.joignable,
    );
  }
}

class SyncNotifier extends Notifier<SyncUiState> {
  @override
  SyncUiState build() => const SyncUiState();

  /// Remonte les ecritures locales, sans rien rapatrier.
  ///
  /// C'est ce que le declenchement automatique appelle. La montee peut se
  /// faire dans le dos de l'agent sans rien deranger : elle n'affecte aucun
  /// pixel de l'ecran. La descente, elle, repeint des listes qu'on est peut-
  /// etre en train de lire, et reste donc a la demande.
  Future<DrainReport> push() async {
    if (state.running) {
      return const DrainReport(
        envoyees: 0,
        restantes: 0,
        arret: DrainStop.horsLigne,
      );
    }
    state = state.copyWith(running: true);

    final rapport = await ref.read(outboxSenderProvider).drain();

    state = state.copyWith(
      running: false,
      push: rapport,
      at: DateTime.now(),
      joignable: rapport.joignable,
    );
    return rapport;
  }

  /// Remonte les ecritures locales, puis rapatrie le referentiel.
  ///
  /// **Cet ordre n'est pas negociable.** La descente ecrase les lignes locales
  /// avec celles du serveur ; tant qu'un check-in n'est pas remonte, le
  /// serveur croit la chambre libre et la rendrait libre sur la tablette. On
  /// pousse donc d'abord. `pullRooms` sait deja epargner les lignes en
  /// attente, mais cette protection ne devrait servir qu'aux cas ou la
  /// remontee vient d'echouer -- pas a tous les echanges.
  ///
  /// N'echoue jamais bruyamment : si le serveur ne repond pas, l'ecran garde
  /// ce qu'il affichait. C'est tout l'interet d'ecrire dans Drift plutot que
  /// de servir directement le reseau aux widgets.
  Future<SyncOutcome> refresh() async {
    if (state.running) return const SyncOutcome.offline();
    state = state.copyWith(running: true);

    final rapport = await ref.read(outboxSenderProvider).drain();
    final outcome = await ref.read(syncRepositoryProvider).pullRooms();

    state = SyncUiState(
      last: outcome,
      at: DateTime.now(),
      push: rapport,
      // La descente est toujours tentee : c'est elle qui tranche, quand la
      // montee n'avait rien a envoyer et n'a donc rien appris.
      joignable: !outcome.offline,
    );
    return outcome;
  }
}

final syncProvider = NotifierProvider<SyncNotifier, SyncUiState>(
  SyncNotifier.new,
);

/// Remonte la file toute seule, sans que personne n'appuie sur rien.
///
/// Retenir une ecriture locale n'apporte rien a personne : plus elle attend,
/// plus il y a a perdre si la tablette tombe. Des qu'il y a quelque chose en
/// file, on essaie.
///
/// Quand le serveur ne repond pas, les tentatives s'espacent au lieu de
/// marteler : une tablette hors ligne pendant deux heures ne doit pas passer
/// deux heures a reessayer toutes les secondes, ni vider sa batterie pour
/// rien.
///
/// Un **blocage** arrete l'automatisme net. Renvoyer en boucle une ecriture
/// que le serveur refuse ne la fera pas passer ; elle attend une decision
/// humaine, et le compteur du bandeau est la pour la reclamer.
class SyncScheduler extends Notifier<void> {
  Timer? _minuteur;
  int _echecs = 0;
  bool _arrete = false;

  static const _premierDelai = Duration(milliseconds: 500);
  static const _delaiMax = Duration(seconds: 60);

  @override
  void build() {
    ref.listen<AsyncValue<int>>(pendingWritesProvider, (_, suivant) {
      final enAttente = suivant.value ?? 0;
      if (enAttente == 0) {
        _annuler();
        _echecs = 0;
        _arrete = false;
        return;
      }
      // Une ecriture vient d'arriver alors que rien n'echouait : on repart
      // sans delai d'attente accumule.
      if (!_arrete && _minuteur == null) _planifier(_premierDelai);
    }, fireImmediately: true);

    ref.onDispose(_annuler);
  }

  /// Force une tentative immediate et repart de zero.
  ///
  /// C'est ce que fait le bouton : un agent qui appuie a une raison de penser
  /// que la situation a change, et n'a pas a subir l'attente accumulee par les
  /// echecs precedents.
  Future<DrainReport> maintenant() {
    _annuler();
    _echecs = 0;
    _arrete = false;
    return _tenter();
  }

  void _planifier(Duration delai) {
    _minuteur?.cancel();
    _minuteur = Timer(delai, () {
      _minuteur = null;
      unawaited(_tenter());
    });
  }

  void _annuler() {
    _minuteur?.cancel();
    _minuteur = null;
  }

  Future<DrainReport> _tenter() async {
    final rapport = await ref.read(syncProvider.notifier).push();

    switch (rapport.arret) {
      case DrainStop.termine:
        _echecs = 0;
        // Le passage est borne : s'il en reste, on enchaine tout de suite.
        if (rapport.restantes > 0) _planifier(_premierDelai);

      case DrainStop.horsLigne:
        _echecs++;
        _planifier(_recul());

      // Ni un renvoi ni l'attente n'y changeront quoi que ce soit.
      case DrainStop.bloque:
      case DrainStop.sessionInvalide:
        _arrete = true;
        _annuler();
    }

    return rapport;
  }

  /// 1s, 2s, 4s… plafonne a une minute.
  Duration _recul() {
    final secondes = 1 << (_echecs - 1).clamp(0, 6);
    final delai = Duration(seconds: secondes);
    return delai > _delaiMax ? _delaiMax : delai;
  }
}

final syncSchedulerProvider = NotifierProvider<SyncScheduler, void>(
  SyncScheduler.new,
);
