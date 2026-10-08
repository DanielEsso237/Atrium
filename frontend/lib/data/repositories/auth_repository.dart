/// Connexion : le serveur d'abord, la base locale s'il ne repond pas.
///
/// C'est ici que se joue la promesse du mode hors connexion pour
/// l'authentification. Trois cas, et trois seulement :
///
/// 1. **Le serveur repond et accepte** — on garde son jeton, et on recopie
///    l'agent dans Drift pour que les ecrans aient un nom a afficher.
/// 2. **Le serveur repond et refuse** — mauvais code ou mauvais secret. On
///    n'essaie **pas** la base locale : accepter localement quelqu'un que le
///    serveur vient de rejeter serait un trou de securite, pas un repli.
/// 3. **Le serveur ne repond pas** — coupure Wi-Fi, serveur eteint. Alors, et
///    alors seulement, on retombe sur la verification locale.
///
/// La distinction entre 2 et 3 est tout l'interet d'avoir separe
/// `ApiFailure.offline` des autres echecs dans `api_client.dart`.
library;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../local/database.dart';
import '../local/enums.dart';
import '../remote/api_client.dart';
import '../remote/auth_api.dart';
import 'agent_repository.dart';

/// Ce qui a echoue, du point de vue de l'ecran de connexion.
enum LoginFailure {
  unknownUser,
  disabledAccount,
  wrongSecret,

  /// Compte verrouille apres cinq echecs. Le serveur le relache au bout de
  /// quinze minutes : le dire, plutot que de laisser l'agent s'acharner sur
  /// un mot de passe qui est peut-etre le bon.
  locked,

  /// Serveur injoignable **et** aucune empreinte locale utilisable.
  offlineAndUnknown,
}

class LoginResult {
  const LoginResult.success(this.user, {required this.online}) : failure = null;
  const LoginResult.failed(this.failure) : user = null, online = false;

  final UserRow? user;
  final LoginFailure? failure;

  /// Vrai si c'est le serveur qui a authentifie, faux si c'est la base locale.
  final bool online;

  bool get succeeded => user != null;
}

class AuthRepository {
  const AuthRepository(this.db, this._api, this._localVerify);

  final AtriumDatabase db;
  final AuthApi _api;

  /// La verification locale, injectee pour rester testable sans base reelle.
  final Future<LoginResult> Function(String code, String secret) _localVerify;

  Future<LoginResult> login({
    required String employeeCode,
    required String secret,
  }) async {
    try {
      final session = await _api.login(
        employeeCode: employeeCode,
        secret: secret,
      );
      final user = await _upsertFromServer(
        session.userId,
        employeeCode,
        session.me,
      );
      return LoginResult.success(user, online: true);
    } on ApiException catch (e) {
      // Seuls ces trois-la sont un jugement du serveur sur l'agent. On ne
      // repasse pas derriere lui.
      switch (e.failure) {
        case ApiFailure.unauthorized:
          return const LoginResult.failed(LoginFailure.wrongSecret);
        case ApiFailure.locked:
          return const LoginResult.failed(LoginFailure.locked);
        case ApiFailure.forbidden:
          return const LoginResult.failed(LoginFailure.disabledAccount);
        default:
          break;
      }
      // Serveur injoignable, ou qui repond de travers (erreur 500, adresse
      // fausse, tunnel ferme) : la tablette verifie elle-meme. Avant, tout ce
      // qui n'etait pas « injoignable » s'affichait « Code incorrect », et
      // l'agent cherchait son erreur alors que le serveur etait en panne.
      if (!e.isOffline) {
        debugPrint('Atrium : connexion refusee par un serveur en erreur '
            '(${e.failure.name}) : ${e.message}. Verification locale.');
      }
      return _localVerify(employeeCode, secret);
    }
  }

  Future<void> logout() => _api.logout();

  /// Recopie l'agent authentifie dans Drift.
  ///
  /// Les ecrans lisent Drift, jamais le reseau : sans cette ligne, le tableau
  /// de bord n'aurait pas de nom a afficher apres une connexion en ligne.
  ///
  /// L'empreinte du secret n'est **pas** recopiee : le serveur ne la renvoie
  /// pas, et `GET /auth/me` ne porte que l'identite et les roles. Tant que la
  /// synchronisation de la table `users` n'existe pas, un agent authentifie
  /// en ligne ne pourra donc pas se reconnecter hors ligne. C'est une limite
  /// connue, pas un oubli -- voir le ticket « moteur de synchronisation ».
  Future<UserRow?> _upsertFromServer(
    String userId,
    String employeeCode,
    Map<String, dynamic> me,
  ) async {
    if (userId.isEmpty) return null;

    // Le serveur a decrit l'agent : identite, roles avec leurs permissions,
    // points de vente. C'est lui qui fait foi sur les droits -- un agent cree
    // depuis l'administration d'un autre poste les recoit ici.
    if (me['id'] == userId) {
      await AgentRepository(db).applyServerAgent(me);
      final applique = await (db.select(
        db.users,
      )..where((u) => u.id.equals(userId))).getSingleOrNull();
      if (applique != null) return applique;
    }

    final existing = await (db.select(
      db.users,
    )..where((u) => u.id.equals(userId))).getSingleOrNull();
    if (existing != null) return existing;

    // L'agent existe sur le serveur mais pas encore sur cette tablette :
    // premiere connexion de quelqu'un dont la fiche n'est pas descendue.
    final now = DateTime.now().toUtc();
    await db
        .into(db.users)
        .insertOnConflictUpdate(
          UsersCompanion.insert(
            id: userId,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotelId,
            employeeCode: employeeCode.trim().toUpperCase(),
            firstName: '',
            lastName: employeeCode.trim().toUpperCase(),
            syncState: const Value(SyncState.synced),
          ),
        );

    return (db.select(
      db.users,
    )..where((u) => u.id.equals(userId))).getSingleOrNull();
  }

  static const _hotelId = '01920000-0000-7000-8000-000000000001';
}
