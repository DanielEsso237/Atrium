/// La caisse d'un agent (cahier des charges, F1.4).
///
/// Un receptionniste prend son poste, compte son fond de caisse, encaisse
/// pendant son service, puis recompte en partant. L'ecart entre ce qu'il
/// compte et ce que l'application attend est le seul chiffre qui compte : il
/// dit si la journee est saine.
///
/// **Un agent n'a qu'une caisse ouverte a la fois.** C'est la regle qui rend
/// tout le reste possible -- le rattachement des encaissements, le calcul de
/// l'attendu, et le fait qu'un renvoi de la file ne puisse pas ouvrir une
/// seconde caisse. Le serveur applique la meme, avec un index unique partiel.
///
/// L'attendu se calcule **en especes seulement**. Une carte ou un paiement
/// mobile ne passe pas par le tiroir : les compter ferait constater un ecart
/// enorme a chaque fermeture.
library;

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// L'etat d'une caisse, tel qu'affiche.
class CashView {
  const CashView({
    required this.session,
    required this.expected,
    required this.cashCollected,
  });

  final CashSessionRow session;

  /// Ce que le tiroir devrait contenir : fond de caisse + especes encaissees.
  final int expected;

  /// Les especes encaissees pendant le service, sans le fond de caisse.
  final int cashCollected;

  bool get open => session.status == CashSessionStatus.OPEN;

  /// Ecart entre le comptage et l'attendu, une fois fermee.
  int? get variance => session.countedAmount == null
      ? null
      : session.countedAmount! - expected;
}

class CashRepository with OutboxWriter {
  CashRepository(this.db);

  @override
  final AtriumDatabase db;

  static const hotelId = '01920000-0000-7000-8000-000000000001';

  /// La caisse ouverte de cet agent, avec son attendu recalcule en continu.
  Stream<CashView?> watchCurrent(String userId) {
    return (db.select(db.cashSessions)
          ..where(
            (c) =>
                c.userId.equals(userId) &
                c.status.equalsValue(CashSessionStatus.OPEN) &
                c.deletedAt.isNull(),
          )
          ..limit(1))
        .watchSingleOrNull()
        .asyncMap((s) async => s == null ? null : _vue(s));
  }

  Future<CashView> _vue(CashSessionRow s) async {
    final especes = await _cashCollected(s.id);
    return CashView(
      session: s,
      expected: s.openingFloat + especes,
      cashCollected: especes,
    );
  }

  /// Les especes encaissees sur cette session.
  ///
  /// Les remboursements se soustraient : ils sortent bien du tiroir.
  Future<int> _cashCollected(String sessionId) async {
    final r = await db
        .customSelect(
          '''
          SELECT COALESCE(SUM(CASE WHEN is_refund = 1 THEN -amount ELSE amount END), 0) AS n
            FROM payments
           WHERE cash_session_id = ?
             AND method = 'CASH'
             AND deleted_at IS NULL
          ''',
          variables: [Variable.withString(sessionId)],
          readsFrom: {db.payments},
        )
        .getSingle();
    return r.read<int>('n');
  }

  /// La session ouverte de l'agent, sans son attendu. Sert au rattachement
  /// d'un encaissement, qui n'a pas besoin du calcul.
  Future<String?> openSessionId(String userId) async {
    final s = await (db.select(db.cashSessions)..where(
          (c) =>
              c.userId.equals(userId) &
              c.status.equalsValue(CashSessionStatus.OPEN) &
              c.deletedAt.isNull(),
        ))
        .getSingleOrNull();
    return s?.id;
  }

  /// Prise de poste : l'agent compte son fond de caisse.
  ///
  /// Idempotent : si une caisse est deja ouverte, on la rend. Rappuyer ne doit
  /// pas couper la journee de l'agent en deux comptages qui ne tomberont
  /// jamais justes.
  Future<String> open({
    required String userId,
    required int openingFloat,
  }) async {
    if (openingFloat < 0) {
      throw StateError('Le fond de caisse ne peut pas etre negatif.');
    }

    final deja = await openSessionId(userId);
    if (deja != null) return deja;

    final id = newId();
    final now = DateTime.now().toUtc();

    await writeAndEnqueue(
      table: 'cash_sessions',
      id: id,
      operation: SyncOp.INSERT,
      payload: {'id': id, 'opening_float': openingFloat},
      action: () => db
          .into(db.cashSessions)
          .insert(
            CashSessionsCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              userId: userId,
              status: const Value(CashSessionStatus.OPEN),
              openedAt: Value(now),
              openingFloat: Value(openingFloat),
              syncState: const Value(SyncState.pending),
            ),
          ),
    );

    return id;
  }

  /// Fin de service : l'agent recompte, l'ecart se constate.
  ///
  /// L'attendu est fige a cet instant, et l'ecart avec lui. Refermer plus tard
  /// ne recalcule rien -- le chiffre constate au comptage est celui que
  /// l'agent a vu, et c'est celui-la qui doit rester.
  Future<int> close({
    required String sessionId,
    required int countedAmount,
  }) async {
    if (countedAmount < 0) {
      throw StateError('Un comptage ne peut pas etre negatif.');
    }

    final s = await (db.select(
      db.cashSessions,
    )..where((c) => c.id.equals(sessionId))).getSingleOrNull();
    if (s == null) throw StateError('Caisse introuvable.');
    if (s.status != CashSessionStatus.OPEN) {
      throw StateError('Cette caisse est deja fermee.');
    }

    final attendu = s.openingFloat + await _cashCollected(sessionId);
    final ecart = countedAmount - attendu;
    final now = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(
        db.cashSessions,
      )..where((c) => c.id.equals(sessionId))).write(
        CashSessionsCompanion(
          status: const Value(CashSessionStatus.CLOSED),
          closedAt: Value(now),
          countedAmount: Value(countedAmount),
          expectedAmount: Value(attendu),
          variance: Value(ecart),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      await enqueue(
        table: 'cash_sessions',
        id: sessionId,
        operation: SyncOp.UPDATE,
        payload: {'id': sessionId, 'counted_amount': countedAmount},
      );
    });

    return ecart;
  }
}
