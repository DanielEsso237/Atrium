/// Une file d'envoi bloquee se voit d'un autre poste (correction 5).
///
/// La tablette bloquee annonce son blocage au serveur, hors de sa file, puis
/// sa levee ; les rapports redescendent vers qui porte `sync.monitor`, qui
/// recoit une alerte et les voit a l'ecran Tablettes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/alert_queries.dart';
import 'package:atrium/data/local/queries/tablettes_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/signalement_blocages.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';
import 'helpers/schema_ancien.dart';

const _recep = '01920000-0000-7000-8000-000000050002';
const _paiement = '01920000-0000-7000-8000-00000000b001';
const _autreTablette = '01920000-0000-7000-8000-00000000ab12';

class _Appel {
  const _Appel(this.methode, this.chemin, this.corps);
  final String methode;
  final String chemin;
  final Map<String, Object?> corps;
}

/// Un serveur qui note ce qu'on lui envoie ; hors ligne a la demande.
class _FauxServeur extends ApiClient {
  _FauxServeur() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final appels = <_Appel>[];
  bool horsLigne = false;

  Future<Map<String, dynamic>> _noter(String m, String path, Object? body) {
    if (horsLigne) {
      throw const ApiException(ApiFailure.offline, 'couloir');
    }
    appels.add(_Appel(m, path, (body as Map?)?.cast<String, Object?>() ?? {}));
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) => _noter('POST', path, body);

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) =>
      _noter('PUT', path, body);
}

void main() {
  late AtriumDatabase db;
  late _FauxServeur serveur;
  late SignalementBlocages signalement;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    serveur = _FauxServeur();
    signalement = SignalementBlocages(db: db, api: serveur);
  });

  tearDown(() => db.close());

  /// Un encaissement refuse par le serveur, et [derriere] saisies apres lui.
  Future<int> refuse({int derriere = 2}) async {
    final now = DateTime.now().toUtc();
    final id = await db
        .into(db.outboxEntries)
        .insert(
          OutboxEntriesCompanion.insert(
            entityTable: 'payments',
            entityId: _paiement,
            op: SyncOp.INSERT,
            payload: jsonEncode({
              'amount': 15000,
              'method': 'CASH',
              'approver_pin': '123456',
            }),
            createdAt: now,
            status: const Value(OutboxStatus.FAILED),
            lastError: const Value('Aucune caisse ouverte.'),
            lastAttemptAt: Value(now),
            authorId: const Value(_recep),
          ),
        );
    for (var i = 0; i < derriere; i++) {
      await db
          .into(db.outboxEntries)
          .insert(
            OutboxEntriesCompanion.insert(
              entityTable: 'guests',
              entityId: '01920000-0000-7000-8000-00000000d00$i',
              op: SyncOp.INSERT,
              payload: '{}',
              createdAt: now,
            ),
          );
    }
    return id;
  }

  Iterable<_Appel> annonces() =>
      serveur.appels.where((a) => a.chemin == '/sync-blocks');
  Iterable<_Appel> levees() =>
      serveur.appels.where((a) => a.chemin.endsWith('/resolve'));

  group('la tablette bloquee le dit', () {
    test('un refus s annonce une fois, sans ses secrets', () async {
      await refuse();

      await signalement.apresPassage();
      await signalement.apresPassage();

      final a = annonces().single.corps;
      expect(a['entity_table'], 'payments');
      expect(a['author_id'], _recep);
      expect(a['reason'], 'Aucune caisse ouverte.');
      expect(a['pending_behind'], 2);
      expect(a['payload'], {'amount': 15000, 'method': 'CASH'});
      final tablette = a['device'] as Map;
      expect(tablette['id'], await db.identifiantTablette());
      expect(tablette['name'], nomParDefaut(tablette['id'] as String));
    });

    test('l identifiant de la tablette ne change pas', () async {
      final premier = await db.identifiantTablette();
      expect(await db.identifiantTablette(), premier);
      expect(nomParDefaut(premier), startsWith('Tablette '));
      expect(nomParDefaut(premier).length, 'Tablette '.length + 4);
    });

    test('ce qui attend derriere change : le rapport repart', () async {
      await refuse(derriere: 1);
      await signalement.apresPassage();
      await refuse(derriere: 0);
      // Un second refus : il a son propre rapport, et le premier voit une
      // saisie de plus derriere lui.
      await signalement.apresPassage();

      expect(annonces().map((a) => a.corps['pending_behind']), [1, 2, 0]);
    });

    test('l ecriture passe : la levee part, une seule fois', () async {
      final entree = await refuse();
      await signalement.apresPassage();
      await (db.update(db.outboxEntries)..where((e) => e.id.equals(entree)))
          .write(const OutboxEntriesCompanion(status: Value(OutboxStatus.ACKED)));

      await signalement.apresPassage();
      await signalement.apresPassage();

      final l = levees().single;
      expect(l.chemin, '/sync-blocks/${annonces().single.corps['id']}/resolve');
      expect(l.corps['resolution'], 'SENT');
      expect(await db.select(db.blockReports).get(), isEmpty);
    });

    test('l ecriture est retiree de la file : levee REMOVED', () async {
      final entree = await refuse();
      await signalement.apresPassage();
      await (db.delete(db.outboxEntries)..where((e) => e.id.equals(entree)))
          .go();

      await signalement.apresPassage();

      expect(levees().single.corps['resolution'], 'REMOVED');
    });

    test('hors ligne, le rapport attend le passage suivant', () async {
      await refuse();
      serveur.horsLigne = true;
      await signalement.apresPassage();
      expect(annonces(), isEmpty);

      serveur.horsLigne = false;
      await signalement.apresPassage();
      expect(annonces(), hasLength(1));
    });

    test('leve avant d avoir ete annonce : rien ne part', () async {
      final entree = await refuse();
      serveur.horsLigne = true;
      await signalement.apresPassage();
      await (db.delete(db.outboxEntries)..where((e) => e.id.equals(entree)))
          .go();
      serveur.horsLigne = false;

      await signalement.apresPassage();

      expect(serveur.appels, isEmpty);
      expect(await db.select(db.blockReports).get(), isEmpty);
    });

    test('la tablette se presente', () async {
      await signalement.presenter();
      final p = serveur.appels.single;
      expect(p.methode, 'PUT');
      expect(p.chemin, '/devices/me');
      expect(p.corps['id'], await db.identifiantTablette());
    });
  });

  group('les autres postes le voient', () {
    Map<String, dynamic> blocage({
      String id = '01920000-0000-7000-8000-00000000bb01',
      String tablette = _autreTablette,
      String statut = 'OPEN',
    }) => {
      'id': id,
      'device_id': tablette,
      'author_id': _recep,
      'entity_table': 'payments',
      'entity_id': _paiement,
      'operation': 'INSERT',
      'payload': {'amount': 15000},
      'reason': 'Aucune caisse ouverte.',
      'blocked_at': '2026-10-26T08:00:00Z',
      'reported_at': '2026-10-26T08:00:05Z',
      'pending_behind': 3,
      'status': statut,
      'resolution': statut == 'OPEN' ? null : 'SENT',
      'resolved_at': statut == 'OPEN' ? null : '2026-10-26T09:00:00Z',
    };

    Future<void> descendre({
      List<Map<String, dynamic>>? tablettes,
      List<Map<String, dynamic>>? blocages,
    }) {
      final api = FakeCatalogApi(devices: tablettes, syncBlocks: blocages);
      return Descente(db, api, SyncRepository(db, api)).pull();
    }

    ContexteAlertes contexte(Set<String> droits) => ContexteAlertes(
      agentId: _recep,
      peut: droits.contains,
      maintenant: DateTime.now(),
    );

    final reception1 = {
      'id': _autreTablette,
      'name': 'Réception 1',
      'is_active': true,
      'app_version': '1.0.0',
      'last_seen_at': '2026-10-26T07:00:00Z',
      'updated_at': '2026-10-26T07:00:00Z',
    };

    test('les blocages descendent, et l ecran les montre', () async {
      await descendre(tablettes: [reception1], blocages: [blocage()]);

      final t = (await db.watchTablettes().first).single;
      expect(t.nom, 'Réception 1');
      expect(t.bloquee, isTrue);
      final b = t.blocages.single;
      expect(b.quoi, 'Encaissement');
      expect(b.montant, 15000);
      expect(b.auteur, 'RECEP01');
      expect(b.derriere, 3);
    });

    test('la liste du serveur remplace celle de la tablette', () async {
      await descendre(tablettes: [reception1], blocages: [blocage()]);
      await descendre(tablettes: [reception1], blocages: const []);
      expect(await db.select(db.syncBlocks).get(), isEmpty);
    });

    test('sans le droit (403), rien n est touche', () async {
      await descendre(tablettes: [reception1], blocages: [blocage()]);
      await descendre();
      expect(await db.select(db.syncBlocks).get(), hasLength(1));
    });

    test('l alerte sonne pour qui suit les tablettes, pas pour les autres',
        () async {
      await descendre(tablettes: [reception1], blocages: [blocage()]);

      final pourLaDirection = await db.chargerAlertes(
        contexte({'sync.monitor'}),
      );
      final alerte = pourLaDirection.singleWhere(
        (a) => a.type == TypeEvenement.tabletteBloquee,
      );
      expect(alerte.titre, 'Tablette bloquée : Réception 1');
      expect(alerte.corps, contains('saisie de RECEP01'));
      expect(alerte.corps, contains('3 saisies attendent derrière'));
      expect(alerte.route, '/tablettes');

      final pourLaReception = await db.chargerAlertes(contexte({}));
      expect(
        pourLaReception.where((a) => a.type == TypeEvenement.tabletteBloquee),
        isEmpty,
      );
    });

    test('un blocage leve ne sonne plus, mais reste a l ecran', () async {
      await descendre(
        tablettes: [reception1],
        blocages: [blocage(statut: 'RESOLVED')],
      );
      final alertes = await db.chargerAlertes(contexte({'sync.monitor'}));
      expect(alertes.where((a) => a.type == TypeEvenement.tabletteBloquee),
          isEmpty);
      final t = (await db.watchTablettes().first).single;
      expect(t.bloquee, isFalse);
      expect(t.blocages.single.resolution, 'SENT');
    });

    test('le blocage de cette tablette ne sonne pas deux fois', () async {
      final ici = await db.identifiantTablette();
      await descendre(blocages: [blocage(tablette: ici)]);

      final alertes = await db.chargerAlertes(contexte({'sync.monitor'}));
      expect(alertes.where((a) => a.type == TypeEvenement.tabletteBloquee),
          isEmpty);
      // L'ecran la montre quand meme, sous son nom par defaut.
      final t = (await db.watchTablettes().first).single;
      expect(t.estCelleCi, isTrue);
      expect(t.bloquee, isTrue);
    });
  });

  test('une tablette deja deployee recoit les deux tables', () async {
    await db.close();
    final dossier = await Directory.systemTemp.createTemp('atrium_');
    final fichier = File('${dossier.path}/atrium.sqlite');
    var base = AtriumDatabase(NativeDatabase(fichier));
    await base.customSelect('SELECT 1').get();
    await base.customStatement('DROP TABLE sync_blocks');
    await base.customStatement('DROP TABLE block_reports');
    await retirerColonnesApres(base, 17);
    await base.customStatement('PRAGMA user_version = 17');
    await base.close();

    base = AtriumDatabase(NativeDatabase(fichier));
    db = base;
    final tables = await base
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('sync_blocks', 'block_reports')",
        )
        .get();
    expect(tables, hasLength(2));
    await dossier.delete(recursive: true);
    // Le montage cree les comptes (empreintes bcrypt) et la base est sur
    // disque : au milieu de la suite complete, il depassait les trente
    // secondes par defaut.
  }, timeout: const Timeout(Duration(minutes: 2)));
}
