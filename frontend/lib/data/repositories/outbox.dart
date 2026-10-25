/// La file d'attente des ecritures, coeur du mode hors connexion (6.3).
///
/// Toute ecriture de l'application suit la meme regle, sans exception :
///
/// 1. elle s'applique **immediatement** dans la base locale, donc l'ecran se
///    met a jour tout de suite, coupure reseau ou non ;
/// 2. elle depose en meme temps une entree dans `outbox_entries`, dans la
///    **meme transaction**.
///
/// Le point 2 est ce qui rend le point 1 honnete. Ecrire dans Drift sans
/// enregistrer l'intention, ce serait perdre la reservation au prochain
/// echange avec le serveur : personne ne saurait qu'elle doit remonter. Les
/// mettre dans une seule transaction garantit qu'on n'a jamais l'un sans
/// l'autre, meme si la tablette s'eteint entre les deux.
///
/// Le moteur qui vide cette file n'existe pas encore — c'est le ticket
/// « moteur de synchronisation ». Les entrees s'accumulent en attendant, ce
/// qui est exactement le comportement attendu d'une tablette hors ligne.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';

/// Ce que tout depot d'ecriture partage.
mixin OutboxWriter {
  AtriumDatabase get db;

  /// Enregistre l'intention de remonter cette ligne au serveur.
  ///
  /// A n'appeler qu'a l'interieur d'une transaction qui ecrit aussi la ligne
  /// elle-meme — voir `writeAndEnqueue`.
  Future<void> enqueue({
    required String table,
    required String id,
    required SyncOp operation,
    required Map<String, Object?> payload,
  }) async {
    await db
        .into(db.outboxEntries)
        .insert(
          OutboxEntriesCompanion.insert(
            entityTable: table,
            entityId: id,
            op: operation,
            // L'etat complet de la ligne, pas un delta : le serveur doit
            // pouvoir appliquer l'entree sans connaitre l'ordre exact des
            // ecritures qui l'ont precedee.
            payload: jsonEncode(payload),
            createdAt: DateTime.now().toUtc(),
            authorId: Value(await db.auteurDeLaFile()),
          ),
        );
  }

  /// Applique une ecriture et l'enfile, en une seule transaction.
  ///
  /// `action` fait l'ecriture metier ; le reste est la plomberie qu'on ne veut
  /// pas voir reecrite, ni surtout oubliee, dans chaque depot.
  Future<T> writeAndEnqueue<T>({
    required String table,
    required String id,
    required SyncOp operation,
    required Map<String, Object?> payload,
    required Future<T> Function() action,
  }) {
    return db.transaction(() async {
      final result = await action();
      await enqueue(
        table: table,
        id: id,
        operation: operation,
        payload: payload,
      );
      return result;
    });
  }
}

/// Nombre d'ecritures qui attendent de remonter.
///
/// Sert a l'indicateur de connexion : un receptionniste doit pouvoir voir
/// qu'il travaille hors ligne et combien d'operations sont en attente, plutot
/// que de le decouvrir a la fin de son service.
///
/// Seulement celles que l'agent connecte peut remonter : les siennes, et
/// celles sans auteur. Celles d'un collegue attendent sa prochaine session
/// ([watchEnvoisDAutrui]) ; les compter ici relancerait la file en boucle
/// sur des ecritures qu'elle ne peut pas envoyer.
extension OutboxRead on AtriumDatabase {
  Stream<int> watchPendingCount() {
    return customSelect(
      'SELECT COUNT(*) AS n FROM outbox_entries '
      "WHERE status IN ('PENDING','FAILED') AND $sqlEnvoyableParLAgent",
      readsFrom: {outboxEntries, syncStatuses},
    ).watchSingle().map((r) => r.read<int>('n'));
  }

  /// Les ecritures des collegues qui attendent leur auteur sur cette
  /// tablette, par agent : « 1 envoi attend RECEP01 ».
  Stream<List<({String agent, int n})>> watchEnvoisDAutrui() {
    return customSelect(
      'SELECT COALESCE(u.employee_code, o.author_id) AS agent, '
      'COUNT(*) AS n FROM outbox_entries o '
      'LEFT JOIN users u ON u.id = o.author_id '
      "WHERE o.status IN ('PENDING','FAILED') AND NOT ($sqlEnvoyableParLAgent) "
      'GROUP BY o.author_id ORDER BY MIN(o.id)',
      readsFrom: {outboxEntries, syncStatuses, users},
    ).watch().map(
      (lignes) => [
        for (final l in lignes)
          (agent: l.read<String>('agent'), n: l.read<int>('n')),
      ],
    );
  }
}

/// Ce que la session en cours peut remonter : ses ecritures, et celles qui
/// n'ont pas d'auteur. Sans agent connecte, ces dernieres seulement.
const sqlEnvoyableParLAgent =
    '(author_id IS NULL OR author_id = '
    '(SELECT user_id FROM sync_statuses WHERE id = 1))';

/// L'agent au nom duquel la tablette ecrit, celui que la session a declare.
extension AuteurDeLaFile on AtriumDatabase {
  Future<String?> auteurDeLaFile() async {
    final ligne = await (select(
      syncStatuses,
    )..where((s) => s.id.equals(1))).getSingleOrNull();
    return ligne?.userId;
  }

  /// A chaque connexion, et `null` a la deconnexion.
  Future<void> declarerAuteur(String? agentId) =>
      into(syncStatuses).insertOnConflictUpdate(
        SyncStatusesCompanion(id: const Value(1), userId: Value(agentId)),
      );
}
