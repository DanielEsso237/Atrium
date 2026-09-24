/// Qui est connecte, et comment il l'a ete.
///
/// La session ne sait pas si c'est le serveur ou la base locale qui a
/// authentifie l'agent — c'est le depot qui tranche. Elle en garde seulement
/// la trace (`online`), pour que l'interface puisse le dire honnetement.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/local/database_provider.dart';
import '../../data/remote/remote_providers.dart';
import '../../data/repositories/auth_repository.dart';
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
  });

  /// Agent connecte, ou `null` si personne ne l'est.
  final UserRow? agent;

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
  @override
  SessionState build() => const SessionState();

  Future<bool> connecter({
    required String codeAgent,
    required String secret,
  }) async {
    state = const SessionState(enCours: true);

    final resultat = await ref
        .read(authRepositoryProvider)
        .login(employeeCode: codeAgent, secret: secret);

    if (resultat.succeeded) {
      state = SessionState(agent: resultat.user, online: resultat.online);
      return true;
    }

    state = SessionState(echec: resultat.failure);
    return false;
  }

  /// Deconnexion : sur une tablette en mode kiosque, c'est l'operation la plus
  /// frequente de la journee — dix agents se succedent sur le meme terminal.
  Future<void> deconnecter() async {
    await ref.read(authRepositoryProvider).logout();
    state = const SessionState();
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(
  SessionNotifier.new,
);
