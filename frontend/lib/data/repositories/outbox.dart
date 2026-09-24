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
extension OutboxRead on AtriumDatabase {
  Stream<int> watchPendingCount() {
    return customSelect(
      "SELECT COUNT(*) AS n FROM outbox_entries WHERE status IN ('PENDING','FAILED')",
      readsFrom: {outboxEntries},
    ).watchSingle().map((r) => r.read<int>('n'));
  }
}
