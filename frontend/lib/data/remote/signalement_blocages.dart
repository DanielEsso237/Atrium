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
///
/// Le rapport dit aussi si l'ecriture peut s'abandonner (correction 6) : un
/// responsable en decide de l'ecran Tablettes, et c'est ici que la tablette
/// bloquee lit sa decision et l'applique (`abandon_ecriture.dart`).
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint, defaultTargetPlatform;

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import '../repositories/abandon_ecriture.dart';
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

  /// Ce que le passage de la file vient de changer, dit au serveur ; puis
  /// les abandons decides d'ailleurs, appliques.
  ///
  /// Vrai si une ecriture vient d'etre abandonnee : la file peut repartir,
  /// et l'appelant la relance sans attendre l'echange suivant.
  Future<bool> apresPassage() async {
    try {
      await _noter();
      await _envoyer();
      if (!await _appliquerDecisions()) return false;
      // L'ecriture a quitte la file : le blocage se leve (`REMOVED`).
      await _noter();
      await _envoyer();
      return true;
    } catch (e, pile) {
      debugPrint('Atrium : signalement du blocage : $e\n$pile');
      return false;
    }
  }

  /// Les decisions qui attendent cette tablette, appliquees. Une ecriture
  /// qui ne s'abandonne plus (une saisie en depend depuis) reste : le
  /// rapport suivant le dit, et le serveur fait tomber la decision.
  Future<bool> _appliquerDecisions() async {
    final rapports = await (db.select(
      db.blockReports,
    )..where((b) => b.resolution.isNull())).get();
    if (rapports.isEmpty) return false;
    final List<dynamic> decisions;
    try {
      decisions = await api.getList(
        '/sync-blocks/decisions',
        query: {'device_id': await db.identifiantTablette()},
      );
    } on ApiException catch (e) {
      debugPrint('Atrium : decisions de la tablette illisibles : $e');
      return false;
    }
    final parId = {for (final r in rapports) r.id: r};
    var applique = false;
    for (final d in decisions) {
      if (d is! Map || d['decision'] != 'ABANDON') continue;
      final r = parId[d['id']];
      if (r == null) continue;
      try {
        await abandonnerEcriture(db, r.outboxEntryId);
        applique = true;
        debugPrint(
          'Atrium : ecriture ${r.outboxEntryId} abandonnee sur decision : '
          '${d['decision_reason']}',
        );
      } on StateError catch (e) {
        debugPrint('Atrium : abandon refuse par la tablette : ${e.message}');
      }
    }
    return applique;
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
      // Recalcule a chaque passage : une saisie arrivee derriere peut
      // dependre de celle-ci.
      final verdict = await abandonnabilite(db, e);
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
                abandonable: Value(verdict.possible),
                abandonNote: Value(verdict.note),
              ),
            );
      } else if (r.resolution == null &&
          (r.pendingBehind != derriere ||
              r.abandonable != verdict.possible ||
              r.abandonNote != verdict.note)) {
        await (db.update(
          db.blockReports,
        )..where((b) => b.id.equals(r.id))).write(
          BlockReportsCompanion(
            pendingBehind: Value(derriere),
            abandonable: Value(verdict.possible),
            abandonNote: Value(verdict.note),
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
        'abandonable': r.abandonable,
        'abandon_note': r.abandonNote,
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
