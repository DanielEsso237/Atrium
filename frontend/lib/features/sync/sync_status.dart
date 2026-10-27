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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/api_client.dart';
import '../../data/remote/catalog_api.dart' show RemoteChanges;
import '../../data/remote/file_uploader.dart';
import '../../data/remote/outbox_sender.dart';
import '../../data/remote/remote_providers.dart';
import '../../data/repositories/descente.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/sync_repository.dart';
import '../auth/session.dart';

class SyncUiState {
  const SyncUiState({
    this.running = false,
    this.last,
    this.at,
    this.push,
    this.pull,
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

  /// Ce qu'a donne la derniere descente des donnees metier.
  final PullReport? pull;

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
    PullReport? pull,
    bool? joignable,
  }) {
    return SyncUiState(
      running: running ?? this.running,
      last: last ?? this.last,
      at: at ?? this.at,
      push: push ?? this.push,
      pull: pull ?? this.pull,
      joignable: joignable ?? this.joignable,
    );
  }
}

class SyncNotifier extends Notifier<SyncUiState> {
  /// Ou en est la tablette dans les changements du serveur : l'instantane
  /// rendu par `/sync/changes`, opaque. En memoire seulement : au demarrage
  /// et a chaque connexion, la relecture complete en fixe un neuf.
  String? _curseur;

  @override
  SyncUiState build() => const SyncUiState();

  /// Un autre agent n'a pas les memes droits : ce que le precedent ne
  /// pouvait pas lire n'est jamais descendu. Sa connexion relit tout.
  ///
  /// C'est la session qui l'appelle. Ecouter la session d'ici rendait ce
  /// fournisseur dependant d'elle, alors qu'elle le lit a chaque connexion :
  /// Riverpod levait `CircularDependencyError` et la relecture qui suit la
  /// connexion ne partait jamais (vu sur la tablette le 25 octobre).
  void oublierCurseur() => _curseur = null;

  /// Vide la file, dit son blocage aux autres postes, et la vide encore si
  /// un responsable vient d'abandonner l'ecriture qui la bloquait : ce qui
  /// attendait derriere part tout de suite, pas a l'echange suivant.
  Future<DrainReport> _remonter() async {
    final envoi = ref.read(outboxSenderProvider);
    final signalement = ref.read(signalementBlocagesProvider);
    final premier = await envoi.drain();
    if (!await signalement.apresPassage()) return premier;
    final second = await envoi.drain();
    await signalement.apresPassage();
    return DrainReport(
      envoyees: premier.envoyees + second.envoyees,
      restantes: second.restantes,
      arret: second.arret,
      detail: second.detail,
    );
  }

  /// Remonte les ecritures locales, sans rien rapatrier.
  ///
  /// C'est ce que le declenchement automatique appelle. La montee peut se
  /// faire dans le dos de l'agent sans rien deranger : elle n'affecte aucun
  /// pixel de l'ecran. La descente, elle, repeint des listes qu'on est peut-
  /// etre en train de lire : automatique, elle passe par [suivre], qui ne
  /// relit que si le serveur signale un changement.
  Future<DrainReport> push() async {
    if (state.running) {
      return const DrainReport(
        envoyees: 0,
        restantes: 0,
        arret: DrainStop.horsLigne,
      );
    }
    state = state.copyWith(running: true);

    // Toujours rendre la main, meme sur une erreur imprevue : sans quoi
    // `running` restait vrai pour toujours. Le bouton tournait sans fin, et
    // chaque tentative suivante abandonnait en voyant un echange « en
    // cours » -- les ecritures restaient dans la file.
    DrainReport rapport;
    try {
      rapport = await _remonter();
    } catch (e, pile) {
      debugPrint('Atrium : la remontee a echoue : $e\n$pile');
      rapport = DrainReport(
        envoyees: 0,
        restantes: 0,
        arret: DrainStop.horsLigne,
        detail: '$e',
      );
    }

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

    final DrainReport rapport;
    final SyncOutcome outcome;
    final PullReport descendu;
    final String? curseur;
    try {
      // Le curseur avant la relecture, jamais apres : ce qui change pendant
      // qu'elle lit reviendra au tour suivant, au lieu de passer entre les
      // mailles.
      curseur = (await ref.read(catalogApiProvider).fetchChanges(null))?.cursor;

      // L'ordre n'est pas negociable : la descente ecrase, la montee non.
      // Pousser d'abord laisse au serveur la chance d'apprendre ce que la
      // tablette sait avant qu'il ne lui reponde.
      // Un blocage, ou sa levee, se dit aux autres postes avant la descente :
      // c'est elle qui leur rapporte ce que les autres tablettes ont dit.
      // Une modification abandonnee sur decision retrouve aussi, par elle,
      // la version du serveur.
      rapport = await _remonter();

      // Le referentiel d'abord : les reservations s'accrochent aux
      // categories de chambres, et une categorie absente ferait ecarter la
      // ligne.
      outcome = await ref.read(syncRepositoryProvider).pullRooms();
      descendu = await ref.read(descenteProvider).pull();
    } catch (e, pile) {
      // Comme pour `push` : une erreur imprevue ne doit jamais laisser
      // l'echange « en cours » pour toujours.
      debugPrint('Atrium : la synchronisation a echoue : $e\n$pile');
      state = state.copyWith(running: false, at: DateTime.now());
      return const SyncOutcome.offline();
    }

    state = SyncUiState(
      last: outcome,
      at: DateTime.now(),
      push: rapport,
      pull: descendu,
      // La descente est toujours tentee : c'est elle qui tranche, quand la
      // montee n'avait rien a envoyer et n'a donc rien appris.
      joignable: !outcome.offline,
    );
    // Une relecture interrompue ne fixe pas de curseur : la suivante
    // recommencera depuis l'ancien.
    if (descendu.succeeded && !outcome.offline) _curseur = curseur;
    return outcome;
  }

  /// Rapatrie ce qui a change sur le serveur, et seulement si quelque chose
  /// a change.
  ///
  /// C'est ce que la descente automatique appelle (`PullScheduler`). Le plus
  /// souvent rien n'a bouge : un seul petit aller-retour, et aucune liste ne
  /// se repeint sous les yeux de l'agent. Sinon, les lignes retirees
  /// partent, puis tout se relit.
  Future<void> suivre() async {
    if (state.running) return;
    final depuis = _curseur;
    if (depuis == null) {
      await refresh();
      return;
    }
    final RemoteChanges? changements;
    try {
      changements = await ref.read(catalogApiProvider).fetchChanges(depuis);
    } on ApiException {
      // Hors ligne, session expiree : le tour suivant reessaiera, et la file
      // d'envoi dit deja ce qui ne va pas.
      return;
    }
    // Un serveur sans la route : la descente reste au bouton, comme avant.
    if (changements == null) return;
    if (changements.rienDeNeuf) {
      _curseur = changements.cursor;
      return;
    }
    if (changements.removed.isNotEmpty) {
      await ref.read(descenteProvider).appliquerRetraits(changements.removed);
    }
    await refresh();
  }
}

/// Rapatrie tout seul ce qui a change sur le serveur (retour du 23 octobre :
/// « implementer la synchro automatique »).
///
/// Toutes les trente secondes, et des que l'application revient au premier
/// plan : une tablette posee le temps d'un menage doit voir l'etat de
/// l'hotel en se rallumant, pas une demi-minute plus tard. Seulement pour un
/// agent connecte en ligne : sans jeton, le serveur ne repondrait rien.
class PullScheduler extends Notifier<void> {
  static const periode = Duration(seconds: 30);

  Timer? _minuteur;
  AppLifecycleListener? _cycle;

  @override
  void build() {
    ref.listen<bool>(
      sessionProvider.select((s) => s.online && s.agent != null),
      (_, enLigne) => enLigne ? _demarrer() : _arreter(),
      fireImmediately: true,
    );
    ref.onDispose(_arreter);
  }

  void _demarrer() {
    _arreter();
    _minuteur = Timer.periodic(periode, (_) => _tour());
    _cycle = AppLifecycleListener(onResume: _tour);
  }

  void _arreter() {
    _minuteur?.cancel();
    _minuteur = null;
    _cycle?.dispose();
    _cycle = null;
  }

  void _tour() => unawaited(ref.read(syncProvider.notifier).suivre());
}

final pullSchedulerProvider = NotifierProvider<PullScheduler, void>(
  PullScheduler.new,
);

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
    // La session repasse en ligne (connexion, ou reprise apres une connexion
    // faite hors ligne) : l'automatisme repart. Sans cela, l'arret pris sur
    // « session invalide » -- une tablette reconnectee hors ligne n'a plus
    // de jeton -- durait jusqu'a la deconnexion, et les ecritures suivantes
    // restaient dans la file.
    ref.listen<bool>(sessionProvider.select((s) => s.online), (avant, enLigne) {
      if (!enLigne || avant == true) return;
      _echecs = 0;
      _arrete = false;
      if ((ref.read(pendingWritesProvider).value ?? 0) > 0) {
        _planifier(_premierDelai);
      }
    });

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
      // Un collegue doit d'abord remonter les siennes : sa prochaine
      // connexion relancera la file.
      case DrainStop.bloque:
      case DrainStop.sessionInvalide:
      case DrainStop.attenteAutrui:
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

/// Remonte les photos toutes seules, a cote de la file d'envoi.
///
/// Distinct de `SyncScheduler` : la file d'envoi ne sait rien des photos, et
/// une photo refusee ou trop lente ne retarde ni n'arrete jamais une
/// ecriture. Le moteur des photos ne leve rien ; son resultat ne touche ni
/// le bandeau ni l'etat de la synchronisation.
///
/// Deux signaux le reveillent : une photo vient d'entrer en file, ou la file
/// d'envoi a bouge -- la creation d'un client vient peut-etre de remonter,
/// et libere la photo qui l'attendait.
class UploadScheduler extends Notifier<void> {
  Timer? _minuteur;
  int _echecs = 0;

  static const _premierDelai = Duration(seconds: 1);

  // Une photo peut attendre un meilleur reseau : inutile de marteler.
  static const _delaiMax = Duration(minutes: 5);

  @override
  void build() {
    ref.listen<AsyncValue<int>>(pendingUploadsProvider, (_, suivant) {
      if ((suivant.value ?? 0) > 0) _bientot();
    }, fireImmediately: true);
    ref.listen<AsyncValue<int>>(pendingWritesProvider, (_, _) {
      if ((ref.read(pendingUploadsProvider).value ?? 0) > 0) _bientot();
    });

    ref.onDispose(_annuler);
  }

  /// Ne raccourcit pas une attente en cours : apres un echec reseau, une
  /// nouvelle photo ne justifie pas de reessayer plus tot.
  void _bientot() {
    if (_minuteur == null) _planifier(_premierDelai);
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

  Future<void> _tenter() async {
    if ((ref.read(pendingUploadsProvider).value ?? 0) == 0) return;

    final rapport = await ref.read(fileUploaderProvider).drain();
    switch (rapport.arret) {
      case UploadStop.termine:
        _echecs = 0;
        if (rapport.lotPlein) _planifier(_premierDelai);

      case UploadStop.horsLigne:
        _echecs++;
        _planifier(_recul());

      // La prochaine connexion relancera la file d'envoi, donc celle-ci.
      case UploadStop.sessionInvalide:
        break;
    }
  }

  /// 2s, 4s, 8s… plafonne a cinq minutes.
  Duration _recul() {
    final delai = Duration(seconds: 1 << _echecs.clamp(1, 9));
    return delai > _delaiMax ? _delaiMax : delai;
  }
}

final uploadSchedulerProvider = NotifierProvider<UploadScheduler, void>(
  UploadScheduler.new,
);
