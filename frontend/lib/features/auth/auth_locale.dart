/// Authentification **locale**, le temps que l'API soit branchee.
///
/// Le cahier des charges (6.2) prevoit login/mot de passe, badge ou code PIN,
/// et la table `users` replique les empreintes sur la tablette : sans elles,
/// plus personne ne pourrait se connecter pendant une coupure reseau, ce qui
/// viderait de son sens tout le mode hors ligne.
///
/// Ce fichier est la version provisoire de cette verification. Quand
/// `POST /auth/login` sera branche, c'est **ici et nulle part ailleurs** que
/// le changement se fera : les ecrans ne connaissent que `AuthLocale`.
library;

import 'package:drift/drift.dart';

import '../../data/local/database.dart';

/// Prefixe des empreintes du jeu de demonstration.
///
/// Une vraie empreinte venue du serveur est un hachage bcrypt, que cette
/// classe ne sait pas verifier. Plutot que d'accepter n'importe quoi en
/// silence, elle refuse tout ce qui ne porte pas ce prefixe : le jour ou de
/// vraies empreintes arriveront sans que le code ait ete remplace, la
/// connexion echouera bruyamment au lieu de laisser passer tout le monde.
const _prefixeDemo = 'DEMO:';

/// Ce qui a echoue, pour afficher un message utile plutot que « erreur ».
enum EchecConnexion { utilisateurInconnu, compteDesactive, secretInvalide }

class ResultatConnexion {
  const ResultatConnexion.reussie(this.utilisateur) : echec = null;
  const ResultatConnexion.echouee(this.echec) : utilisateur = null;

  final UserRow? utilisateur;
  final EchecConnexion? echec;

  bool get estReussie => utilisateur != null;
}

class AuthLocale {
  const AuthLocale(this._db);

  final AtriumDatabase _db;

  /// Cherche l'agent par son code, puis verifie son secret.
  ///
  /// Le code est normalise en majuscules : personne ne doit echouer a se
  /// connecter parce que le clavier tactile a mis une minuscule.
  Future<ResultatConnexion> connecter({
    required String codeAgent,
    required String secret,
  }) async {
    final code = codeAgent.trim().toUpperCase();

    final utilisateurs = await (_db.select(_db.users)
          ..where((u) => u.employeeCode.equals(code) & u.deletedAt.isNull())
          ..limit(1))
        .get();

    if (utilisateurs.isEmpty) {
      return const ResultatConnexion.echouee(EchecConnexion.utilisateurInconnu);
    }

    final utilisateur = utilisateurs.first;
    if (!utilisateur.isActive) {
      return const ResultatConnexion.echouee(EchecConnexion.compteDesactive);
    }

    if (!verifierSecret(secret, utilisateur.pinHash) &&
        !verifierSecret(secret, utilisateur.passwordHash)) {
      return const ResultatConnexion.echouee(EchecConnexion.secretInvalide);
    }

    await (_db.update(_db.users)..where((u) => u.id.equals(utilisateur.id)))
        .write(UsersCompanion(lastLoginAt: Value(DateTime.now().toUtc())));

    return ResultatConnexion.reussie(utilisateur);
  }

  /// TODO(api) : remplacer par la verification du serveur, puis par bcrypt
  /// local pour le mode hors ligne. Voir le ticket « couche de liaison ».
  ///
  /// Comparaison en clair assumee et volontairement bornee au jeu de
  /// demonstration — voir `_prefixeDemo`.
  static bool verifierSecret(String saisi, String? empreinte) {
    if (empreinte == null || !empreinte.startsWith(_prefixeDemo)) return false;
    return empreinte.substring(_prefixeDemo.length) == saisi;
  }
}
