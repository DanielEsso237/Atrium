/// L'ecriture que le serveur refuse, et qui bloque la file derriere elle.
///
/// Un refus ne se resout pas en renvoyant : la file s'arrete, volontairement,
/// et attend une decision humaine. Jusqu'ici, rien ne permettait de la
/// prendre -- vecu le 11 octobre : un encaissement de trop, refuse par le
/// serveur, et huit saisies bloquees derriere sans recours.
///
/// Seul un encaissement se retire pour l'instant : il n'a rien qui en
/// depende, et son retrait se defait proprement (la ligne disparait, le solde
/// de l'ardoise se recalcule). Retirer un sejour ou une reservation laisserait
/// la tablette et le serveur en desaccord durable.
library;

import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';
import 'folio_repository.dart';

class EcritureRefusee {
  const EcritureRefusee({
    required this.entreeId,
    required this.table,
    required this.ligneId,
    required this.operation,
    this.raison,
  });

  final int entreeId;
  final String table;
  final String ligneId;
  final SyncOp operation;
  final String? raison;

  /// Un encaissement : il se retire sans rien casser.
  bool get retirable =>
      table == 'payments' && operation == SyncOp.INSERT;
}

/// La premiere ecriture refusee de la file, ou `null`.
Future<EcritureRefusee?> ecritureRefusee(AtriumDatabase db) async {
  final e = await (db.select(db.outboxEntries)
        ..where((o) => o.status.equalsValue(OutboxStatus.FAILED))
        ..orderBy([(o) => OrderingTerm(expression: o.id)])
        ..limit(1))
      .getSingleOrNull();
  if (e == null) return null;
  return EcritureRefusee(
    entreeId: e.id,
    table: e.entityTable,
    ligneId: e.entityId,
    operation: e.op,
    raison: e.lastError,
  );
}

/// Retire un encaissement refuse : de la file, de la tablette, et de
/// l'ardoise dont le solde se recalcule. Leve une [StateError] pour une
/// ecriture qui ne se retire pas.
Future<void> retirerEcritureRefusee(
  AtriumDatabase db,
  EcritureRefusee e,
) async {
  if (!e.retirable) {
    throw StateError('Cette écriture ne se retire pas depuis la tablette.');
  }
  await db.transaction(() async {
    final paiement = await (db.select(db.payments)
          ..where((p) => p.id.equals(e.ligneId)))
        .getSingleOrNull();
    await (db.delete(db.outboxEntries)
          ..where(
            (o) => o.entityTable.equals('payments') & o.entityId.equals(e.ligneId),
          ))
        .go();
    await (db.delete(db.payments)..where((p) => p.id.equals(e.ligneId))).go();
    final ardoise = paiement?.folioId;
    if (ardoise != null) await FolioRepository(db).recalculer(ardoise);
  });
}
