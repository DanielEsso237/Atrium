/// Qui est connecte, et comment il l'a ete.
///
/// La session ne sait pas si c'est le serveur ou la base locale qui a
/// authentifie l'agent — c'est le depot qui tranche. Elle en garde seulement
/// la trace (`online`), pour que l'interface puisse le dire honnetement.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/access_queries.dart';
import '../../data/remote/remote_providers.dart';
import '../../data/repositories/auth_repository.dart';
import '../sync/sync_status.dart';
import 'auth_locale.dart';

final authLocaleProvider = Provider<AuthLocale>(
  (ref) => AuthLocale(ref.watch(databaseProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final locale = ref.watch(authLocaleProvider);

  return AuthRepository(
    ref.watch(databaseProvider),
    ref.watch(authApiProvider),
    // Le pont vers la verification locale : le depot ne connait pas
    // `AuthLocale`, il connait une fonction qui rend un `LoginResult`.
    (code, secret) async {
      final r = await locale.connecter(codeAgent: code, secret: secret);
      if (r.estReussie) {
        return LoginResult.success(r.utilisateur, online: false);
      }
      return LoginResult.failed(switch (r.echec!) {
        EchecConnexion.utilisateurInconnu => LoginFailure.offlineAndUnknown,
        EchecConnexion.compteDesactive => LoginFailure.disabledAccount,
        EchecConnexion.secretInvalide => LoginFailure.wrongSecret,
      });
    },
  );
});

class SessionState {
  const SessionState({
    this.agent,
    this.enCours = false,
    this.echec,
    this.online = false,
    this.acces = const AccessProfile(),
  });

  /// Agent connecte, ou `null` si personne ne l'est.
  final UserRow? agent;

  /// Ce a quoi cet agent a droit (3.4).
  ///
  /// Charge a la connexion, en meme temps que l'agent : les deux vont
  /// ensemble, et un ecran qui aurait l'un sans l'autre afficherait soit tout,
  /// soit rien, le temps d'une reconstruction.
  final AccessProfile acces;

  /// Une tentative de connexion est en cours.
  final bool enCours;

  final LoginFailure? echec;

  /// Vrai si c'est le serveur qui a authentifie, faux si c'est la base locale.
  ///
  /// Sert a dire a l'agent ou il en est. Une tablette qui travaille hors
  /// ligne doit le montrer au moment ou ca arrive.
  final bool online;

  bool get estConnecte => agent != null;

  String get nomAffiche {
    if (agent == null) return '';
    final prenom = agent!.firstName.trim();
    return prenom.isEmpty ? agent!.lastName : '$prenom ${agent!.lastName}';
  }
}

class SessionNotifier extends Notifier<SessionState> {
  /// La prochaine tentative de reprise en ligne, apres une connexion faite
  /// hors ligne.
  Timer? _reprise;

  /// Le code et le secret de l'agent connecte hors ligne, **en memoire
  /// seulement** et le temps de la reprise : sans eux, impossible d'obtenir
  /// un jeton du serveur une fois revenu. Effaces des que la reprise reussit,
  /// echoue pour de bon, ou que l'agent se deconnecte.
  (String, String)? _identifiants;

  /// Premier essai rapide -- a froid, le tunnel et le HTTPS depassent
  /// souvent le delai de la connexion --, puis toutes les 30 s.
  static const premiereReprise = Duration(seconds: 5);
  static const intervalleReprise = Duration(seconds: 30);

  @override
  SessionState build() {
    ref.onDispose(_oublierReprise);
    return const SessionState();
  }

  void _oublierReprise() {
    _reprise?.cancel();
    _reprise = null;
    _identifiants = null;
  }

  void _planifierReprise(Duration delai) {
    _reprise?.cancel();
    _reprise = Timer(delai, () => unawaited(_tenterEnLigne()));
  }

  Future<void> _tenterEnLigne() async {
    final identifiants = _identifiants;
    final agent = state.agent;
    if (identifiants == null || agent == null || state.online) return;

    final issue = await ref
        .read(authRepositoryProvider)
        .reconnecter(employeeCode: identifiants.$1, secret: identifiants.$2);
    // L'agent a pu se deconnecter pendant l'essai.
    if (_identifiants != identifiants || state.agent?.id != agent.id) return;

    switch (issue) {
      case Reprise.enLigne:
        _oublierReprise();
        state = SessionState(
          agent: state.agent,
          online: true,
          // Les droits viennent du serveur a la connexion en ligne.
          acces: await accessProfileFor(ref.read(databaseProvider), agent.id),
        );
        unawaited(ref.read(syncProvider.notifier).refresh());
      case Reprise.injoignable:
        _planifierReprise(intervalleReprise);
      case Reprise.refusee:
        _oublierReprise();
    }
  }

  Future<bool> connecter({
    required String codeAgent,
    required String secret,
  }) async {
    state = const SessionState(enCours: true);

    final resultat = await ref
        .read(authRepositoryProvider)
        .login(employeeCode: codeAgent, secret: secret);

    if (resultat.succeeded) {
      final acces = await accessProfileFor(
        ref.read(databaseProvider),
        resultat.user!.id,
      );
      state = SessionState(
        agent: resultat.user,
        online: resultat.online,
        acces: acces,
      );

      // Connexion en ligne : on rapatrie le referentiel dans la foulee, sans
      // attendre. L'ecran s'affiche tout de suite avec ce que la base
      // contient deja, et se repeint quand les vraies donnees arrivent.
      if (resultat.online) {
        _oublierReprise();
        unawaited(ref.read(syncProvider.notifier).refresh());
      } else {
        // Hors ligne : on retente le serveur en arriere-plan, et la session
        // passe en ligne toute seule quand il revient.
        _identifiants = (codeAgent, secret);
        _planifierReprise(premiereReprise);
      }
      return true;
    }

    state = SessionState(echec: resultat.failure);
    return false;
  }

  /// Deconnexion : sur une tablette en mode kiosque, c'est l'operation la plus
  /// frequente de la journee — dix agents se succedent sur le meme terminal.
  Future<void> deconnecter() async {
    _oublierReprise();
    await ref.read(authRepositoryProvider).logout();
    state = const SessionState();
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(
  SessionNotifier.new,
);
