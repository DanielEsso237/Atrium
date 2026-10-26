/// Une file d'envoi bloquee se dit au serveur, pour se voir d'un autre poste.
///
/// Un refus du serveur bloque la file, avec tout ce qui attend derriere --
/// et cela ne se voyait que sur la tablette elle-meme. La reception pouvait
/// travailler une demi-journee sans que rien ne remonte, et personne d'autre
/// ne le savait.
///
/// Apres chaque passage de la file, la tablette annonce chaque ecriture
/// refusee (`POST /sync-blocks`), puis sa levee quand elle passe ou quitte
/// la file (`/resolve`). **Hors de la file d'envoi** : elle est justement
/// bloquee. Ce que la tablette a deja dit vit dans `block_reports`, pour ne
/// rien redire et ne rien oublier d'une coupure a l'autre.
///
/// Jamais bloquant : un rapport qui ne part pas repartira au passage suivant,
/// et rien ici ne leve d'exception vers la file.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint, defaultTargetPlatform;

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'api_client.dart';

/// La version de l'application, donnee a la compilation
/// (`--dart-define=ATRIUM_VERSION=…`) ; absente, le serveur n'en sait rien.
const _version = String.fromEnvironment('ATRIUM_VERSION');

/// Le contenu d'un changement de PIN ou d'un code oublie porte des secrets.
/// Le serveur les retire aussi ; ils ne partent pas pour autant.
const _motsSecrets = {'secret', 'password', 'pin', 'token', 'hash'};

/// [valeur] sans les cles qui designent un secret, a toute profondeur. Par
/// mot de la cle (`approver_pin`), pas par sous-chaine : `shipping` reste.
Object? sansSecrets(Object? valeur) {
  if (valeur is Map) {
    return {
      for (final e in valeur.entries)
        if (!'${e.key}'.toLowerCase().split('_').any(_motsSecrets.contains))
          '${e.key}': sansSecrets(e.value),
    };
  }
  if (valeur is List) return [for (final v in valeur) sansSecrets(v)];
  return valeur;
}

extension IdentiteTablette on AtriumDatabase {
  /// L'identifiant de cette tablette, tire au premier besoin et garde.
  ///
  /// Il la reconnait d'un agent a l'autre : c'est la tablette qui est
  /// bloquee, pas l'agent connecte.
  Future<String> identifiantTablette() async {
    final ligne = await (select(
      syncStatuses,
    )..where((s) => s.id.equals(1))).getSingleOrNull();
    final connu = ligne?.deviceId;
    if (connu != null) return connu;
    final neuf = newId();
    await into(syncStatuses).insertOnConflictUpdate(
      SyncStatusesCompanion(id: const Value(1), deviceId: Value(neuf)),
    );
    return neuf;
  }
}

/// Le nom d'une tablette tant que l'administrateur ne lui en a pas donne un :
/// « Tablette 3F2A », les quatre derniers caracteres de son identifiant.
String nomParDefaut(String identifiant) =>
    'Tablette ${identifiant.substring(identifiant.length - 4).toUpperCase()}';

class SignalementBlocages {
  SignalementBlocages({required this.db, required this.api});

  final AtriumDatabase db;
  final ApiClient api;

  Future<Map<String, Object?>> _tablette() async {
    final id = await db.identifiantTablette();
    return {
      'id': id,
      'name': nomParDefaut(id),
      'app_version': _version.isEmpty ? null : _version,
      'os_version': defaultTargetPlatform.name,
    };
  }

  /// La tablette se presente au serveur, a chaque connexion en ligne : elle
  /// figure ainsi a l'ecran Tablettes avant meme d'avoir ete bloquee.
  Future<void> presenter() async {
    try {
      await api.put('/devices/me', body: await _tablette());
    } catch (e) {
      debugPrint('Atrium : la tablette ne s\'est pas presentee : $e');
    }
  }

  /// Ce que le passage de la file vient de changer, dit au serveur.
  Future<void> apresPassage() async {
    try {
      await _noter();
      await _envoyer();
    } catch (e, pile) {
      debugPrint('Atrium : signalement du blocage : $e\n$pile');
    }
  }

  /// Un rapport par ecriture refusee, et la levee de ceux dont l'ecriture
  /// n'est plus refusee.
  Future<void> _noter() => db.transaction(() async {
    final refusees = await (db.select(
      db.outboxEntries,
    )..where((e) => e.status.equalsValue(OutboxStatus.FAILED))).get();
    final rapports = await db.select(db.blockReports).get();
    final parEntree = {for (final r in rapports) r.outboxEntryId: r};
    final maintenant = DateTime.now().toUtc();

    for (final e in refusees) {
      final derriere = await _derriere(e.id);
      final r = parEntree[e.id];
      if (r == null) {
        await db
            .into(db.blockReports)
            .insert(
              BlockReportsCompanion.insert(
                id: newId(),
                outboxEntryId: e.id,
                blockedAt: e.lastAttemptAt ?? maintenant,
                pendingBehind: Value(derriere),
              ),
            );
      } else if (r.resolution == null && r.pendingBehind != derriere) {
        await (db.update(
          db.blockReports,
        )..where((b) => b.id.equals(r.id))).write(
          BlockReportsCompanion(
            pendingBehind: Value(derriere),
            aEnvoyer: const Value(true),
          ),
        );
      }
    }

    final encoreRefusees = {for (final e in refusees) e.id};
    for (final r in rapports) {
      if (r.resolution != null || encoreRefusees.contains(r.outboxEntryId)) {
        continue;
      }
      if (r.reportedAt == null) {
        // Leve avant d'avoir ete annonce : le serveur n'a rien a apprendre.
        await (db.delete(
          db.blockReports,
        )..where((b) => b.id.equals(r.id))).go();
        continue;
      }
      final entree = await (db.select(
        db.outboxEntries,
      )..where((e) => e.id.equals(r.outboxEntryId))).getSingleOrNull();
      await (db.update(
        db.blockReports,
      )..where((b) => b.id.equals(r.id))).write(
        BlockReportsCompanion(
          resolution: Value(
            entree?.status == OutboxStatus.ACKED ? 'SENT' : 'REMOVED',
          ),
          resolvedAt: Value(maintenant),
        ),
      );
    }
  });

  /// Les ecritures qui attendent derriere [entreeId], tous auteurs confondus.
  Future<int> _derriere(int entreeId) async {
    final r = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM outbox_entries '
          "WHERE status IN ('PENDING','FAILED') AND id > ?",
          variables: [Variable.withInt(entreeId)],
          readsFrom: {db.outboxEntries},
        )
        .getSingle();
    return r.read<int>('n');
  }

  Future<void> _envoyer() async {
    final rapports = await db.select(db.blockReports).get();
    for (final r in rapports) {
      try {
        if (r.resolution == null && r.aEnvoyer) {
          await _annoncer(r);
        } else if (r.resolution != null) {
          await _lever(r);
        }
      } on ApiException catch (e) {
        // Hors ligne ou session perdue : le reste attendra le passage suivant.
        if (e.isOffline || e.failure == ApiFailure.unauthorized) return;
        debugPrint('Atrium : rapport de blocage refuse : $e');
      }
    }
  }

  Future<void> _annoncer(BlockReportRow r) async {
    final e = await (db.select(
      db.outboxEntries,
    )..where((o) => o.id.equals(r.outboxEntryId))).getSingleOrNull();
    if (e == null) return;
    Object? contenu;
    try {
      contenu = sansSecrets(jsonDecode(e.payload));
    } on FormatException {
      contenu = null;
    }
    await api.post(
      '/sync-blocks',
      body: {
        'id': r.id,
        'device': await _tablette(),
        'author_id': e.authorId,
        'entity_table': e.entityTable,
        'entity_id': e.entityId,
        'operation': e.op.name,
        'payload': contenu is Map ? contenu : null,
        'reason': e.lastError,
        'written_at': e.createdAt.toUtc().toIso8601String(),
        'blocked_at': r.blockedAt.toUtc().toIso8601String(),
        'pending_behind': r.pendingBehind,
      },
    );
    await (db.update(
      db.blockReports,
    )..where((b) => b.id.equals(r.id))).write(
      BlockReportsCompanion(
        aEnvoyer: const Value(false),
        reportedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> _lever(BlockReportRow r) async {
    try {
      await api.post(
        '/sync-blocks/${r.id}/resolve',
        body: {
          'resolution': r.resolution,
          'resolved_at': r.resolvedAt!.toUtc().toIso8601String(),
        },
      );
    } on ApiException catch (e) {
      // Le serveur ne le connait pas : il n'y a rien a lever.
      if (e.failure != ApiFailure.notFound) rethrow;
    }
    // Dit au serveur : la ligne n'a plus d'usage ici.
    await (db.delete(db.blockReports)..where((b) => b.id.equals(r.id))).go();
  }
}
