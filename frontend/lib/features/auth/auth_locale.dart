/// Authentification **locale** : quand le serveur ne repond pas.
///
/// Le cahier des charges (6.2) prevoit login/mot de passe, badge ou code PIN,
/// et la table `users` replique les empreintes sur la tablette : sans elles,
/// plus personne ne pourrait se connecter pendant une coupure reseau, ce qui
/// viderait de son sens tout le mode hors ligne.
///
/// Les empreintes sont celles du serveur, des hachages bcrypt, descendues par
/// `GET /auth/credentials` (`Descente`). Les comptes de demonstration gardent
/// leur prefixe `DEMO:`. La regle de blocage est celle du serveur
/// (`app/services/verrouillage.py`), recopiee a la lettre : ce que le serveur
/// refuse, la tablette le refuse aussi.
library;

import 'package:bcrypt/bcrypt.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show compute;

import '../../data/local/database.dart';
import '../../data/local/queries/access_queries.dart';

/// Prefixe des empreintes du jeu de demonstration.
const _prefixeDemo = 'DEMO:';

/// Cinq codes faux bloquent un compte (decision du 21 octobre).
const echecsMax = 5;

/// Un responsable bloque attend ; personne au-dessus de lui ne le
/// debloquerait.
const attenteResponsable = Duration(minutes: 15);

/// Le droit de reinitialiser le code d'un agent -- et d'etre un responsable
/// au sens du blocage.
const droitReinitialiser = 'users.reset_secret';

/// Ce qui a echoue, pour afficher un message utile plutot que « erreur ».
enum EchecConnexion {
  utilisateurInconnu,
  compteDesactive,
  secretInvalide,
  compteBloque,
}

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
    final utilisateur = await agentParCode(_db, codeAgent);
    if (utilisateur == null) {
      return const ResultatConnexion.echouee(EchecConnexion.utilisateurInconnu);
    }
    if (!utilisateur.isActive) {
      return const ResultatConnexion.echouee(EchecConnexion.compteDesactive);
    }
    final maintenant = DateTime.now().toUtc();
    if (await estBloque(_db, utilisateur, maintenant)) {
      return const ResultatConnexion.echouee(EchecConnexion.compteBloque);
    }
    if (!await secretAccepte(secret, utilisateur)) {
      await compterEchec(_db, utilisateur, maintenant);
      return const ResultatConnexion.echouee(EchecConnexion.secretInvalide);
    }

    await (_db.update(
      _db.users,
    )..where((u) => u.id.equals(utilisateur.id))).write(
      UsersCompanion(
        lastLoginAt: Value(maintenant),
        failedLoginCount: const Value(0),
        lockedUntil: const Value(null),
      ),
    );

    return ResultatConnexion.reussie(utilisateur);
  }

  /// Mot de passe **ou** PIN, sans que l'agent ait a dire lequel -- comme le
  /// serveur (`secret_accepte`).
  static Future<bool> secretAccepte(String saisi, UserRow agent) async =>
      await verifierSecret(saisi, agent.pinHash) ||
      await verifierSecret(saisi, agent.passwordHash);

  /// Une empreinte bcrypt du serveur, ou `DEMO:` pour la demonstration.
  ///
  /// Tout autre format est refuse : accepter en silence ce qu'on ne sait pas
  /// verifier laisserait passer tout le monde.
  static Future<bool> verifierSecret(String saisi, String? empreinte) async {
    if (empreinte == null || saisi.isEmpty) return false;
    if (empreinte.startsWith(_prefixeDemo)) {
      return empreinte.substring(_prefixeDemo.length) == saisi;
    }
    if (!empreinte.startsWith(r'$2')) return false;
    // bcrypt est lent par construction (un quart de seconde au serveur,
    // davantage sur une tablette) : hors du fil de l'interface, sinon le
    // pave numerique gele a chaque code.
    return compute(_bcryptAccepte, (saisi, empreinte));
  }

  /// L'empreinte d'un secret choisi hors ligne, en attendant celle du
  /// serveur. Cout 10 : elle ne vit que jusqu'a la prochaine descente.
  static Future<String> empreinte(String secret) =>
      compute(_bcryptHacher, secret);
}

bool _bcryptAccepte((String, String) e) {
  try {
    return BCrypt.checkpw(e.$1, e.$2);
  } catch (_) {
    // Une empreinte illisible ne doit ni planter la connexion ni l'ouvrir.
    return false;
  }
}

String _bcryptHacher(String secret) =>
    BCrypt.hashpw(secret, BCrypt.gensalt(prefix: r'$2b', logRounds: 10));

/// L'agent actif ou non, par son code, hors fiches supprimees.
Future<UserRow?> agentParCode(AtriumDatabase db, String code) =>
    (db.select(db.users)
          ..where(
            (u) =>
                u.employeeCode.equals(code.trim().toUpperCase()) &
                u.deletedAt.isNull(),
          )
          ..limit(1))
        .getSingleOrNull();

Future<bool> _estResponsable(AtriumDatabase db, String userId) async =>
    (await accessProfileFor(db, userId)).peut(droitReinitialiser);

/// Bloque : un agent jusqu'a ce qu'un responsable le debloque, un
/// responsable un quart d'heure.
Future<bool> estBloque(
  AtriumDatabase db,
  UserRow agent,
  DateTime maintenant,
) async {
  if (agent.failedLoginCount < echecsMax) return false;
  if (await _estResponsable(db, agent.id)) {
    final jusqua = agent.lockedUntil;
    return jusqua != null && jusqua.isAfter(maintenant);
  }
  return true;
}

/// Un code faux de plus. Etat local, qui ne remonte pas : le serveur tient
/// son propre compte, et la descente des empreintes fait foi.
Future<void> compterEchec(
  AtriumDatabase db,
  UserRow agent,
  DateTime maintenant,
) async {
  final echecs = agent.failedLoginCount + 1;
  final bloqueJusqua =
      echecs >= echecsMax && await _estResponsable(db, agent.id)
      ? maintenant.add(attenteResponsable)
      : agent.lockedUntil;
  await (db.update(db.users)..where((u) => u.id.equals(agent.id))).write(
    UsersCompanion(
      failedLoginCount: Value(echecs),
      lockedUntil: Value(bloqueJusqua),
    ),
  );
}
