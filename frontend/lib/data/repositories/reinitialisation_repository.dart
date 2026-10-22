/// Code oublie : un responsable le reinitialise sur place (21 octobre).
///
/// L'agent touche « Code oublie ? » sur l'ecran de connexion, un responsable
/// (`users.reset_secret`) tape **son** code sur la tablette, et l'agent
/// choisit un nouveau PIN, un nouveau mot de passe, ou les deux. Son compte
/// est debloque.
///
/// Le meme partage que la connexion (`AuthRepository`) :
///
/// 1. le serveur repond -- il juge, et la tablette recopie le nouveau code
///    pour la connexion hors ligne ;
/// 2. le serveur ne repond pas -- la tablette verifie le responsable avec ce
///    qu'elle connait, ecrit le nouveau code et l'enfile. L'agent se
///    connecte aussitot.
///
/// Ce qui part par la file porte le code du responsable **et son secret** :
/// l'agent n'a pas de session, c'est ce secret que le serveur reverifie. Il
/// est efface de la file des que le serveur a repondu, comme le PIN d'un
/// agent cree depuis l'administration.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../features/auth/auth_locale.dart';
import '../local/database.dart';
import '../local/enums.dart';
import '../local/queries/access_queries.dart';
import '../remote/api_client.dart';
import '../remote/auth_api.dart';
import 'outbox.dart';

/// L'action portee par l'entree de file.
const actionReinitialiser = 'RESET_SECRET';

/// Ce que le serveur ne doit pas trouver dans l'historique de la file.
const _secretsDeLaFile = ['approver_secret', 'new_pin', 'new_password', 'pin'];

class ReinitialisationRepository with OutboxWriter {
  ReinitialisationRepository(this.db, this._api);

  @override
  final AtriumDatabase db;
  final AuthApi _api;

  /// Reinitialise le code de [codeAgent]. Leve une [StateError] dont le
  /// message se lit tel quel a l'ecran.
  Future<void> reinitialiser({
    required String codeAgent,
    required String codeResponsable,
    required String secretResponsable,
    String? nouveauPin,
    String? nouveauMotDePasse,
  }) async {
    // Les memes regles que le serveur (`ResetSecretIn`), avant tout envoi.
    if (nouveauPin == null && nouveauMotDePasse == null) {
      throw StateError('Choisissez un nouveau code PIN ou un mot de passe.');
    }
    if (nouveauPin != null && !RegExp(r'^\d{4,8}$').hasMatch(nouveauPin)) {
      throw StateError('Le PIN compte de 4 à 8 chiffres.');
    }
    if (nouveauMotDePasse != null && nouveauMotDePasse.length < 8) {
      throw StateError('Le mot de passe compte au moins 8 caractères.');
    }
    final agent = codeAgent.trim().toUpperCase();
    final responsable = codeResponsable.trim().toUpperCase();
    if (agent == responsable) {
      throw StateError(
        'Un autre responsable doit valider : on ne réinitialise pas son '
        'propre code.',
      );
    }
    final corps = <String, Object?>{
      'employee_code': agent,
      'approver_code': responsable,
      'approver_secret': secretResponsable,
      'new_pin': ?nouveauPin,
      'new_password': ?nouveauMotDePasse,
    };

    try {
      await _api.resetSecret(corps);
      // Le serveur a le nouveau code ; la tablette en garde l'empreinte
      // pour la connexion hors ligne, sans rien enfiler.
      final ligne = await agentParCode(db, agent);
      if (ligne != null) {
        await _ecrire(
          ligne.id,
          nouveauPin,
          nouveauMotDePasse,
          SyncState.synced,
        );
      }
      return;
    } on ApiException catch (e) {
      switch (e.failure) {
        case ApiFailure.forbidden:
        case ApiFailure.locked:
        case ApiFailure.invalid:
          throw StateError(e.message);
        case ApiFailure.notFound:
          throw StateError('Code agent inconnu.');
        default:
          break;
      }
    }
    await _horsLigne(agent, responsable, secretResponsable, corps);
  }

  Future<void> _horsLigne(
    String codeAgent,
    String codeResponsable,
    String secret,
    Map<String, Object?> corps,
  ) async {
    final agent = await agentParCode(db, codeAgent);
    if (agent == null) {
      throw StateError(
        'Serveur injoignable, et cet agent est inconnu de cette tablette.',
      );
    }
    if (!agent.isActive) throw StateError('Ce compte est désactivé.');

    final responsable = await agentParCode(db, codeResponsable);
    final maintenant = DateTime.now().toUtc();
    if (responsable != null && await estBloque(db, responsable, maintenant)) {
      throw StateError('Compte du responsable bloqué après cinq codes faux.');
    }
    if (responsable == null ||
        !responsable.isActive ||
        !await AuthLocale.secretAccepte(secret, responsable)) {
      if (responsable != null) {
        await compterEchec(db, responsable, maintenant);
      }
      throw StateError(
        'Code du responsable incorrect, ou inconnu de cette tablette hors '
        'ligne.',
      );
    }
    final acces = await accessProfileFor(db, responsable.id);
    if (!acces.peut(droitReinitialiser)) {
      final nom = '${responsable.firstName} ${responsable.lastName}'.trim();
      throw StateError("$nom n'a pas le droit de réinitialiser un code.");
    }

    final nouveauPin = corps['new_pin'] as String?;
    final nouveauMotDePasse = corps['new_password'] as String?;
    // Les empreintes avant la transaction : bcrypt prend son temps, et la
    // base resterait verrouillee pendant ce temps-la.
    final empreintePin = nouveauPin == null
        ? null
        : await AuthLocale.empreinte(nouveauPin);
    final empreinteMotDePasse = nouveauMotDePasse == null
        ? null
        : await AuthLocale.empreinte(nouveauMotDePasse);
    await writeAndEnqueue(
      table: 'users',
      id: agent.id,
      operation: SyncOp.UPDATE,
      payload: {'id': agent.id, 'action': actionReinitialiser, ...corps},
      action: () => _ecrireEmpreintes(
        agent.id,
        empreintePin,
        empreinteMotDePasse,
        // En attente : la descente n'ecrase pas le nouveau code par
        // l'ancien tant qu'il n'est pas remonte.
        SyncState.pending,
      ),
    );
  }

  Future<void> _ecrire(
    String id,
    String? pin,
    String? motDePasse,
    SyncState etat,
  ) async => _ecrireEmpreintes(
    id,
    pin == null ? null : await AuthLocale.empreinte(pin),
    motDePasse == null ? null : await AuthLocale.empreinte(motDePasse),
    etat,
  );

  Future<void> _ecrireEmpreintes(
    String id,
    String? empreintePin,
    String? empreinteMotDePasse,
    SyncState etat,
  ) async {
    await (db.update(db.users)..where((u) => u.id.equals(id))).write(
      UsersCompanion(
        pinHash: empreintePin == null
            ? const Value.absent()
            : Value(empreintePin),
        passwordHash: empreinteMotDePasse == null
            ? const Value.absent()
            : Value(empreinteMotDePasse),
        mustChangePassword: empreinteMotDePasse == null
            ? const Value.absent()
            : const Value(false),
        failedLoginCount: const Value(0),
        lockedUntil: const Value(null),
        syncState: Value(etat),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// Fait remonter, avant une connexion en ligne, les reinitialisations de
  /// [codeAgent] encore dans la file.
  ///
  /// Sans cela, l'agent reinitialise hors ligne se presentait au serveur
  /// avec un code que celui-ci ne connaissait pas encore : refus, et pas de
  /// repli local -- un refus du serveur n'en a jamais. Et la file ne se
  /// vidait pas non plus, faute de session. Ces entrees-la n'ont pas besoin
  /// de jeton ; elles partent donc avant leur tour, sans rien changer a
  /// l'ordre du reste, qui ne parle pas des codes.
  ///
  /// Silencieux : hors ligne ou refusee, l'entree reste dans la file, et la
  /// connexion suit son cours.
  Future<void> remonterEnAttente(String codeAgent) async {
    final code = codeAgent.trim().toUpperCase();
    final entrees =
        await (db.select(db.outboxEntries)
              ..where(
                (e) =>
                    e.entityTable.equals('users') &
                    e.status.isInValues([
                      OutboxStatus.PENDING,
                      OutboxStatus.FAILED,
                    ]),
              )
              ..orderBy([(e) => OrderingTerm(expression: e.id)]))
            .get();
    for (final entree in entrees) {
      final p = jsonDecode(entree.payload) as Map<String, dynamic>;
      if (p['action'] != actionReinitialiser || p['employee_code'] != code) {
        continue;
      }
      try {
        await _api.resetSecret(corpsPourLeServeur(p));
      } on ApiException {
        return;
      }
      await db.transaction(() async {
        await effacerSecrets(db, entree.id);
        await (db.update(
          db.outboxEntries,
        )..where((e) => e.id.equals(entree.id))).write(
          OutboxEntriesCompanion(
            status: const Value(OutboxStatus.ACKED),
            lastAttemptAt: Value(DateTime.now().toUtc()),
          ),
        );
        await (db.update(db.users)..where((u) => u.id.equals(entree.entityId)))
            .write(const UsersCompanion(syncState: Value(SyncState.synced)));
      });
    }
  }

  /// Le corps de `POST /auth/reset-secret`, tire d'une entree de file.
  static Map<String, Object?> corpsPourLeServeur(Map<String, dynamic> p) => {
    'employee_code': p['employee_code'],
    'approver_code': p['approver_code'],
    'approver_secret': p['approver_secret'],
    'new_pin': ?p['new_pin'],
    'new_password': ?p['new_password'],
  };

  /// Retire de l'entree tout secret, une fois le serveur servi : la tablette
  /// n'en garde aucune copie, pas meme dans l'historique de sa file.
  static Future<void> effacerSecrets(AtriumDatabase db, int entreeId) =>
      db.customUpdate(
        'UPDATE outbox_entries SET payload = json_remove(payload, '
        "${_secretsDeLaFile.map((c) => "'\$.$c'").join(', ')}) "
        'WHERE id = ?',
        variables: [Variable.withInt(entreeId)],
        updates: {db.outboxEntries},
      );
}
