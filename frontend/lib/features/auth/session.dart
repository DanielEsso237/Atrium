/// Qui est connecte, et sur quel ecran l'application doit se trouver.
///
/// L'agent connecte vit ici plutot que dans l'ecran de connexion : le tableau
/// de bord affiche son nom, et c'est cet objet que la couche reseau remplacera
/// par un vrai jeton sans que les ecrans changent.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/local/database_provider.dart';
import 'auth_locale.dart';

final authLocaleProvider = Provider<AuthLocale>(
  (ref) => AuthLocale(ref.watch(databaseProvider)),
);

class SessionState {
  const SessionState({this.agent, this.enCours = false, this.echec});

  /// Agent connecte, ou `null` si personne ne l'est.
  final UserRow? agent;

  /// Une tentative de connexion est en cours.
  final bool enCours;

  final EchecConnexion? echec;

  bool get estConnecte => agent != null;

  String get nomAffiche =>
      agent == null ? '' : '${agent!.firstName} ${agent!.lastName}';
}

class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState();

  Future<bool> connecter({
    required String codeAgent,
    required String secret,
  }) async {
    state = const SessionState(enCours: true);

    final resultat = await ref.read(authLocaleProvider).connecter(
          codeAgent: codeAgent,
          secret: secret,
        );

    if (resultat.estReussie) {
      state = SessionState(agent: resultat.utilisateur);
      return true;
    }

    state = SessionState(echec: resultat.echec);
    return false;
  }

  /// Deconnexion : sur une tablette en mode kiosque, c'est l'operation la plus
  /// frequente de la journee — dix agents se succedent sur le meme terminal.
  void deconnecter() => state = const SessionState();
}

final sessionProvider =
    NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);
