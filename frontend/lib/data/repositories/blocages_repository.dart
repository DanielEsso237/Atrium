/// Abandonner, d'un autre poste, l'ecriture qui bloque une tablette
/// (correction 6).
///
/// La decision part **directement** au serveur, pas par la file d'envoi :
/// elle n'a de sens qu'en ligne -- c'est le serveur qui la transmet a la
/// tablette bloquee --, et la file du poste qui decide peut etre bloquee
/// elle-meme. La reponse s'ecrit aussitot dans `sync_blocks`, pour que
/// l'ecran Tablettes la montre sans attendre la descente.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';
import '../remote/api_client.dart';

/// Une ligne de `sync_blocks` telle que le serveur la rend.
SyncBlocksCompanion blocageDuServeur(
  Map<String, dynamic> b, {
  required String hotelId,
  required DateTime maintenant,
}) {
  final contenu = b['payload'];
  return SyncBlocksCompanion.insert(
    id: b['id'] as String,
    createdAt: maintenant,
    updatedAt: _instant(b['updated_at']) ?? maintenant,
    hotelId: hotelId,
    deviceId: b['device_id'] as String,
    authorId: Value(b['author_id'] as String?),
    reportedBy: Value(b['reported_by'] as String?),
    entityTable: b['entity_table'] as String,
    entityId: b['entity_id'] as String,
    operation: b['operation'] as String,
    payload: Value(contenu == null ? null : jsonEncode(contenu)),
    httpStatus: Value(b['http_status'] as int?),
    reason: Value(b['reason'] as String?),
    writtenAt: Value(_instant(b['written_at'])),
    blockedAt: _instant(b['blocked_at']) ?? maintenant,
    reportedAt: _instant(b['reported_at']) ?? maintenant,
    pendingBehind: Value(b['pending_behind'] as int? ?? 0),
    status: Value(b['status'] as String? ?? 'OPEN'),
    resolvedAt: Value(_instant(b['resolved_at'])),
    resolution: Value(b['resolution'] as String?),
    abandonable: Value(b['abandonable'] as bool? ?? false),
    abandonNote: Value(b['abandon_note'] as String?),
    decision: Value(b['decision'] as String?),
    decisionReason: Value(b['decision_reason'] as String?),
    decidedBy: Value(b['decided_by'] as String?),
    decidedAt: Value(_instant(b['decided_at'])),
    syncState: const Value(SyncState.synced),
  );
}

DateTime? _instant(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toUtc() : null;

class BlocagesRepository {
  BlocagesRepository({required this.db, required this.api});

  final AtriumDatabase db;
  final ApiClient api;

  /// Abandonne l'ecriture du blocage [blocageId], avec le [motif] du
  /// responsable. Rend `null` si le serveur l'a enregistre, sinon ce qu'il
  /// faut dire : hors ligne, ou le refus du serveur -- la tablette bloquee
  /// n'en veut plus (409), l'agent n'en a pas le droit (403).
  Future<String?> abandonner(String blocageId, String motif) async {
    final Map<String, dynamic> reponse;
    try {
      reponse = await api.post(
        '/sync-blocks/$blocageId/decide',
        body: {'decision': 'ABANDON', 'reason': motif.trim()},
      );
    } on ApiException catch (e) {
      return e.isOffline
          ? 'Serveur injoignable : l’abandon se décide en ligne.'
          : e.message;
    }
    final local = await (db.select(
      db.syncBlocks,
    )..where((b) => b.id.equals(blocageId))).getSingleOrNull();
    if (local == null) return null;
    await db
        .into(db.syncBlocks)
        .insertOnConflictUpdate(
          blocageDuServeur(
            reponse,
            hotelId: local.hotelId,
            maintenant: DateTime.now().toUtc(),
          ),
        );
    return null;
  }
}
