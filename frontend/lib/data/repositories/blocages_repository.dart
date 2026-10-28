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

/// Une ligne de `devices` telle que le serveur la rend. Seul le serveur les
/// ecrit : rien a epargner.
DevicesCompanion tabletteDuServeur(
  Map<String, dynamic> t, {
  required String hotelId,
  required DateTime maintenant,
}) {
  final id = t['id'] as String;
  return DevicesCompanion.insert(
    id: id,
    createdAt: maintenant,
    updatedAt: _instant(t['updated_at']) ?? maintenant,
    hotelId: hotelId,
    deviceUid: id,
    name: t['name'] as String,
    isActive: Value(t['is_active'] as bool? ?? true),
    appVersion: Value(t['app_version'] as String?),
    osVersion: Value(t['os_version'] as String?),
    lastSeenAt: Value(_instant(t['last_seen_at'])),
    revokedAt: Value(_instant(t['revoked_at'])),
    revokedBy: Value(t['revoked_by'] as String?),
    revocationReason: Value(t['revocation_reason'] as String?),
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

  /// Donne un nom parlant a une tablette (« Réception 1 »). Comme
  /// [abandonner] : `null` si le serveur l'a enregistre, sinon quoi dire.
  Future<String?> renommer(String tabletteId, String nom) => _tablette(
    () => api.patch('/devices/$tabletteId', body: {'name': nom.trim()}),
  );

  /// Revoque une tablette perdue ou volee : a son prochain contact avec le
  /// serveur, elle efface sa base et sa cle (correction 9).
  Future<String?> revoquer(String tabletteId, String motif) => _tablette(
    () => api.post(
      '/devices/$tabletteId/revoke',
      body: {'reason': motif.trim()},
    ),
  );

  Future<String?> _tablette(
    Future<Map<String, dynamic>> Function() requete,
  ) async {
    final Map<String, dynamic> reponse;
    try {
      reponse = await requete();
    } on ApiException catch (e) {
      return e.isOffline
          ? 'Serveur injoignable : cela se fait en ligne.'
          : e.message;
    }
    final local = await (db.select(
      db.devices,
    )..where((d) => d.id.equals(reponse['id'] as String))).getSingleOrNull();
    if (local == null) return null;
    await db
        .into(db.devices)
        .insertOnConflictUpdate(
          tabletteDuServeur(
            reponse,
            hotelId: local.hotelId,
            maintenant: DateTime.now().toUtc(),
          ),
        );
    return null;
  }
}
