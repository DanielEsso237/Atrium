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
import '../../data/repositories/repository_providers.dart';
import '../sync/sync_status.dart';
import 'auth_locale.dart';
import 'pin_input.dart' show longueurAncienPin;

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
        EchecConnexion.compteBloque => LoginFailure.locked,
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
    this.pinAChanger = false,
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

  /// L'agent s'est connecte avec un ancien PIN de 4 chiffres : il en choisit
  /// un de 6 avant d'aller plus loin (decision du 25 octobre). Le routeur ne
  /// lui ouvre que cet ecran-la.
  final bool pinAChanger;

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

  /// L'ancien PIN, **en memoire seulement**, le temps que l'agent en
  /// choisisse un nouveau : c'est lui que le serveur reverifie.
  String? _ancienPin;

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

  /// Vrai si [pin] est l'ancien code de 4 chiffres de [codeAgent], d'apres
  /// l'empreinte que la tablette connait. Ne compte aucun echec : c'est un
  /// essai silencieux au quatrieme chiffre, pas une connexion.
  Future<bool> estAncienCode(String codeAgent, String pin) async {
    if (pin.length != longueurAncienPin || codeAgent.trim().isEmpty) {
      return false;
    }
    final agent = await agentParCode(ref.read(databaseProvider), codeAgent);
    return agent != null &&
        await AuthLocale.verifierSecret(pin, agent.pinHash);
  }

  /// Remplace l'ancien PIN de 4 chiffres par [nouveau]. Leve une
  /// [StateError] dont le message se lit tel quel a l'ecran.
  Future<void> changerPin(String nouveau) async {
    final agent = state.agent;
    final ancien = _ancienPin;
    if (agent == null || ancien == null) return;
    await ref
        .read(reinitialisationRepositoryProvider)
        .changerPin(
          codeAgent: agent.employeeCode,
          ancien: ancien,
          nouveau: nouveau,
        );
    if (state.agent?.id != agent.id) return;
    _ancienPin = null;
    // La reprise en ligne se presentera avec le nouveau code : l'ancien ne
    // marchera plus une fois le changement remonte.
    final identifiants = _identifiants;
    if (identifiants != null) _identifiants = (identifiants.$1, nouveau);
    state = SessionState(
      agent: state.agent,
      online: state.online,
      acces: state.acces,
    );
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
          pinAChanger: state.pinAChanger,
          // Les droits viennent du serveur a la connexion en ligne.
          acces: await accessProfileFor(ref.read(databaseProvider), agent.id),
        );
        unawaited(_synchroniserPuisRelire(agent.id));
      case Reprise.injoignable:
        _planifierReprise(intervalleReprise);
      case Reprise.refusee:
        _oublierReprise();
    }
  }

  /// [parPin] : le secret vient du pave PIN, pas du champ mot de passe. Un
  /// mot de passe de 4 chiffres n'existe pas (8 caracteres au moins), mais
  /// le dire evite de le deviner a la longueur.
  Future<bool> connecter({
    required String codeAgent,
    required String secret,
    bool parPin = false,
  }) async {
    state = const SessionState(enCours: true);
    _ancienPin = null;

    final resultat = await ref
        .read(authRepositoryProvider)
        .login(employeeCode: codeAgent, secret: secret);

    if (resultat.succeeded) {
      ref.read(syncProvider.notifier).oublierCurseur();
      final acces = await accessProfileFor(
        ref.read(databaseProvider),
        resultat.user!.id,
      );
      final pinAChanger = parPin && secret.length == longueurAncienPin;
      if (pinAChanger) _ancienPin = secret;
      state = SessionState(
        agent: resultat.user,
        online: resultat.online,
        acces: acces,
        pinAChanger: pinAChanger,
      );

      // Connexion en ligne : on rapatrie le referentiel dans la foulee, sans
      // attendre. L'ecran s'affiche tout de suite avec ce que la base
      // contient deja, et se repeint quand les vraies donnees arrivent.
      if (resultat.online) {
        _oublierReprise();
        unawaited(_synchroniserPuisRelire(resultat.user!.id));
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

  /// Synchronise, puis relit les droits de l'agent.
  ///
  /// Sur un poste neuf, les droits se calculaient avant que les points de
  /// vente ne descendent : le genre du bar etait inconnu, et le barman voyait
  /// l'onglet Services jusqu'a sa connexion suivante (vu le 12 octobre).
  Future<void> _synchroniserPuisRelire(String agentId) async {
    await ref.read(syncProvider.notifier).refresh();
    // L'agent a pu se deconnecter, ou un autre se connecter, entre-temps.
    if (state.agent?.id != agentId) return;
    final acces = await accessProfileFor(ref.read(databaseProvider), agentId);
    if (state.agent?.id != agentId) return;
    state = SessionState(
      agent: state.agent,
      online: state.online,
      acces: acces,
      pinAChanger: state.pinAChanger,
    );
  }

  /// Deconnexion : sur une tablette en mode kiosque, c'est l'operation la plus
  /// frequente de la journee — dix agents se succedent sur le meme terminal.
  Future<void> deconnecter() async {
    _oublierReprise();
    _ancienPin = null;
    await ref.read(authRepositoryProvider).logout();
    state = const SessionState();
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(
  SessionNotifier.new,
);
