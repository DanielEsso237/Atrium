/// Une ecriture refusee s'abandonne d'un autre poste (correction 6).
///
/// La tablette bloquee dit dans son rapport si l'ecriture peut s'abandonner ;
/// un responsable en decide de l'ecran Tablettes ; la tablette lit la
/// decision a son passage suivant, la reverifie, l'applique, et sa file
/// repart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/tablettes_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/signalement_blocages.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/abandon_ecriture.dart';
import 'package:atrium/data/repositories/blocages_repository.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _agent = '01920000-0000-7000-8000-000000050002';
const _ardoise = '01920000-0000-7000-8000-00000000e002';
const _client = '01920000-0000-7000-8000-00000000c001';

/// Un serveur qui note ce qu'on lui envoie et rend les decisions qu'on lui
/// a donnees.
class _FauxServeur extends ApiClient {
  _FauxServeur() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final posts = <(String, Map<String, Object?>)>[];
  final decisions = <Map<String, Object?>>[];
  bool horsLigne = false;
  ApiException? refus;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    if (horsLigne) throw const ApiException(ApiFailure.offline, 'couloir');
    if (refus != null) throw refus!;
    final corps = (body as Map?)?.cast<String, Object?>() ?? {};
    posts.add((path, corps));
    if (path.endsWith('/decide')) {
      return {
        'id': path.split('/')[2],
        'device_id': '01920000-0000-7000-8000-00000000ab12',
        'entity_table': 'payments',
        'entity_id': '01920000-0000-7000-8000-00000000b001',
        'operation': 'INSERT',
        'blocked_at': '2026-10-26T08:00:00Z',
        'reported_at': '2026-10-26T08:00:05Z',
        'status': 'OPEN',
        'abandonable': true,
        'decision': 'ABANDON',
        'decision_reason': corps['reason'],
        'decided_at': '2026-10-26T09:00:00Z',
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};

  @override
  Future<List<dynamic>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (horsLigne) throw const ApiException(ApiFailure.offline, 'couloir');
    return path == '/sync-blocks/decisions' ? decisions : const [];
  }
}

void main() {
  late AtriumDatabase db;
  late _FauxServeur serveur;
  late SignalementBlocages signalement;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    serveur = _FauxServeur();
    signalement = SignalementBlocages(db: db, api: serveur);
    final now = DateTime.now().toUtc();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: _ardoise,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            number: 'FOL-000031',
          ),
        );
  });

  tearDown(() => db.close());

  Future<OutboxEntryRow> entree(int id) => (db.select(
    db.outboxEntries,
  )..where((o) => o.id.equals(id))).getSingle();

  /// La derniere entree de la file, marquee refusee par le serveur.
  Future<OutboxEntryRow> refuserLaDerniere() async {
    final derniere = await (db.select(db.outboxEntries)
          ..orderBy([(o) => OrderingTerm.desc(o.id)])
          ..limit(1))
        .getSingle();
    await (db.update(
      db.outboxEntries,
    )..where((o) => o.id.equals(derniere.id))).write(
      const OutboxEntriesCompanion(
        status: Value(OutboxStatus.FAILED),
        lastError: Value('Ce folio est deja solde.'),
      ),
    );
    return entree(derniere.id);
  }

  /// Une nuitee de 25 000 et un encaissement du tout, refuse par le serveur.
  Future<OutboxEntryRow> encaissementRefuse() async {
    final ardoises = FolioRepository(db);
    await ardoises.addCharge(
      folioId: _ardoise,
      category: ChargeCategory.ROOM,
      label: 'Nuitee',
      unitPrice: 25000,
    );
    await CashRepository(db).open(userId: _agent, openingFloat: 0);
    await ardoises.addPayment(
      folioId: _ardoise,
      method: PaymentMethod.CASH,
      amount: 25000,
      receivedBy: _agent,
    );
    // Ce qui precede est remonte ; seul l'encaissement est refuse.
    await (db.update(db.outboxEntries)
          ..where((o) => o.entityTable.isNotValue('payments')))
        .write(const OutboxEntriesCompanion(status: Value(OutboxStatus.ACKED)));
    return refuserLaDerniere();
  }

  Future<int> solde() async => (await (db.select(
    db.folios,
  )..where((f) => f.id.equals(_ardoise))).getSingle()).balance;

  Future<void> enfiler(String table, String id, Map<String, Object?> p,
      {SyncOp op = SyncOp.INSERT}) => db
      .into(db.outboxEntries)
      .insert(
        OutboxEntriesCompanion.insert(
          entityTable: table,
          entityId: id,
          op: op,
          payload: jsonEncode(p),
          createdAt: DateTime.now().toUtc(),
        ),
      );

  group('la tablette bloquee dit ce qui s abandonne', () {
    test('un encaissement seul : oui, et le rapport le dit', () async {
      final e = await encaissementRefuse();
      expect((await abandonnabilite(db, e)).possible, isTrue);

      await signalement.apresPassage();
      final annonce = serveur.posts.singleWhere((p) => p.$1 == '/sync-blocks');
      expect(annonce.$2['abandonable'], isTrue);
      expect(annonce.$2['abandon_note'], isNull);
    });

    test('son annulation l attend derriere : non', () async {
      final e = await encaissementRefuse();
      await enfiler('payments', '01920000-0000-7000-8000-00000000f001', {
        'action': 'REVERSE',
        'reverses_payment_id': e.entityId,
        'folio_id': _ardoise,
      });

      final verdict = await abandonnabilite(db, e);
      expect(verdict.possible, isFalse);
      expect(verdict.note, contains('Une saisie suivante en dépend'));
    });

    test('une cloture de l ardoise suppose l encaissement : non', () async {
      final e = await encaissementRefuse();
      await enfiler('folios', _ardoise, {'id': _ardoise, 'status': 'CLOSED'});
      expect((await abandonnabilite(db, e)).possible, isFalse);
    });

    test('un encaissement ou une consommation de plus : oui', () async {
      final e = await encaissementRefuse();
      await enfiler('folio_items', '01920000-0000-7000-8000-00000000f002', {
        'folio_id': _ardoise,
      });
      await enfiler('payments', '01920000-0000-7000-8000-00000000f003', {
        'folio_id': _ardoise,
      });
      expect((await abandonnabilite(db, e)).possible, isTrue);
    });

    test('une consommation suivie d un encaissement : non', () async {
      await FolioRepository(db).addCharge(
        folioId: _ardoise,
        category: ChargeCategory.FNB,
        label: 'Biere',
        unitPrice: 1500,
      );
      final e = await refuserLaDerniere();
      await enfiler('payments', '01920000-0000-7000-8000-00000000f004', {
        'folio_id': _ardoise,
      });
      // Le solde de l'encaissement comptait sur la biere.
      expect((await abandonnabilite(db, e)).possible, isFalse);
    });

    test('un sejour en entraine d autres : non, et la note le dit', () async {
      await enfiler('reservation_rooms', _ardoise, {'status': 'CHECKED_IN'});
      final e = await refuserLaDerniere();
      final verdict = await abandonnabilite(db, e);
      expect(verdict.possible, isFalse);
      expect(verdict.note, contains('en entraîne d’autres'));
    });
  });

  group('la decision s applique au passage suivant', () {
    Future<String> annoncer() async {
      await signalement.apresPassage();
      return serveur.posts.firstWhere((p) => p.$1 == '/sync-blocks').$2['id']
          as String;
    }

    test('un encaissement abandonne : retire, l ardoise se recalcule, '
        'la file repart', () async {
      await encaissementRefuse();
      expect(await solde(), 0);
      final rapport = await annoncer();
      serveur.decisions.add({
        'id': rapport,
        'decision': 'ABANDON',
        'decision_reason': 'Encaisse deux fois',
      });

      expect(await signalement.apresPassage(), isTrue);

      expect(await db.select(db.payments).get(), isEmpty);
      expect(await solde(), 25000);
      expect(
        await (db.select(db.outboxEntries)..where(
              (o) => o.status.equalsValue(OutboxStatus.FAILED),
            ))
            .get(),
        isEmpty,
      );
      final levee = serveur.posts.singleWhere(
        (p) => p.$1 == '/sync-blocks/$rapport/resolve',
      );
      expect(levee.$2['resolution'], 'REMOVED');
      // Une fois appliquee, rien ne se refait.
      serveur.decisions.clear();
      expect(await signalement.apresPassage(), isFalse);
    });

    test('une saisie en depend depuis : la decision ne s applique pas, et '
        'le rapport le redit', () async {
      final e = await encaissementRefuse();
      final rapport = await annoncer();
      await enfiler('payments', '01920000-0000-7000-8000-00000000f005', {
        'action': 'REVERSE',
        'reverses_payment_id': e.entityId,
      });
      serveur.decisions.add({'id': rapport, 'decision': 'ABANDON'});
      serveur.posts.clear();

      expect(await signalement.apresPassage(), isFalse);

      expect(await db.select(db.payments).get(), hasLength(1));
      final redit = serveur.posts.singleWhere((p) => p.$1 == '/sync-blocks');
      expect(redit.$2['id'], rapport);
      expect(redit.$2['abandonable'], isFalse);
      expect(redit.$2['abandon_note'], contains('en dépend'));
    });

    test('une decision pour une autre ecriture ne touche a rien', () async {
      await encaissementRefuse();
      await annoncer();
      serveur.decisions.add({
        'id': '01920000-0000-7000-8000-00000000dead',
        'decision': 'ABANDON',
      });
      expect(await signalement.apresPassage(), isFalse);
      expect(await db.select(db.payments).get(), hasLength(1));
    });

    test('une fiche client modifiee : la version du serveur reviendra',
        () async {
      final now = DateTime.now().toUtc();
      await db
          .into(db.guests)
          .insert(
            GuestsCompanion.insert(
              id: _client,
              createdAt: now,
              updatedAt: now,
              hotelId: _hotel,
              code: 'CLI-000777',
              firstName: 'Awa',
              lastName: 'Ndiaye',
              phone: const Value('+221 00 refuse'),
              syncState: const Value(SyncState.pending),
            ),
          );
      await enfiler('guests', _client, {
        'id': _client,
        'phone': '+221 00 refuse',
      }, op: SyncOp.UPDATE);
      final e = await refuserLaDerniere();
      final sync = SyncRepository(db, const FakeCatalogApi());
      expect(await sync.lignesEnAttente(db.guests), contains(_client));

      await abandonnerEcriture(db, e.id);

      // Plus protegee : la descente suivante l'ecrase.
      expect(await sync.lignesEnAttente(db.guests), isNot(contains(_client)));
      expect(await db.select(db.guests).get(), isNotEmpty);
    });

    test('une vente abandonnee rend au stock ce qu elle avait pris',
        () async {
      final now = DateTime.now().toUtc();
      const produit = '01920000-0000-7000-8000-00000000a503';
      const magasin = '01920000-0000-7000-8000-00000000a504';
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: produit,
              createdAt: now,
              updatedAt: now,
              hotelId: _hotel,
              reference: 'BIE-33',
              label: 'Biere 33 cl',
            ),
          );
      await db
          .into(db.stockLocations)
          .insert(
            StockLocationsCompanion.insert(
              id: magasin,
              createdAt: now,
              updatedAt: now,
              hotelId: _hotel,
              code: 'BAR',
              label: 'Bar',
            ),
          );
      await db
          .into(db.stockLevels)
          .insertOnConflictUpdate(
            StockLevelsCompanion.insert(
              id: '01920000-0000-7000-8000-00000000a501',
              createdAt: now,
              updatedAt: now,
              productId: produit,
              stockLocationId: magasin,
              quantity: const Value(10),
            ),
          );
      await FolioRepository(db).addCharge(
        folioId: _ardoise,
        category: ChargeCategory.FNB,
        label: 'Biere',
        unitPrice: 1500,
        quantity: 2,
      );
      final e = await refuserLaDerniere();
      await db
          .into(db.stockMovements)
          .insert(
            StockMovementsCompanion.insert(
              id: '01920000-0000-7000-8000-00000000a502',
              createdAt: now,
              updatedAt: now,
              hotelId: _hotel,
              productId: produit,
              stockLocationId: magasin,
              type: StockMovementType.OUT,
              quantity: 2,
              sourceTable: const Value('folio_items'),
              sourceId: Value(e.entityId),
            ),
          );
      await db.customStatement(
        "UPDATE stock_levels SET quantity = 8 WHERE id = "
        "'01920000-0000-7000-8000-00000000a501'",
      );

      await abandonnerEcriture(db, e.id);

      expect(await db.select(db.folioItems).get(), isEmpty);
      expect(await db.select(db.stockMovements).get(), isEmpty);
      final niveau = await (db.select(db.stockLevels)..where(
            (l) => l.id.equals('01920000-0000-7000-8000-00000000a501'),
          ))
          .getSingle();
      expect(niveau.quantity, 10);
      expect(await solde(), 0);
    });

    test('hors ligne, rien ne s applique', () async {
      await encaissementRefuse();
      final rapport = await annoncer();
      serveur.decisions.add({'id': rapport, 'decision': 'ABANDON'});
      serveur.horsLigne = true;
      expect(await signalement.apresPassage(), isFalse);
      expect(await db.select(db.payments).get(), hasLength(1));
    });
  });

  group('l autre poste decide', () {
    const blocage = '01920000-0000-7000-8000-00000000bb01';

    setUp(() async {
      final now = DateTime.now().toUtc();
      await db
          .into(db.syncBlocks)
          .insert(
            SyncBlocksCompanion.insert(
              id: blocage,
              createdAt: now,
              updatedAt: now,
              hotelId: _hotel,
              deviceId: '01920000-0000-7000-8000-00000000ab12',
              entityTable: 'payments',
              entityId: '01920000-0000-7000-8000-00000000b001',
              operation: 'INSERT',
              blockedAt: now,
              reportedAt: now,
              abandonable: const Value(true),
            ),
          );
    });

    test('la decision part au serveur et se voit aussitot', () async {
      final refus = await BlocagesRepository(
        db: db,
        api: serveur,
      ).abandonner(blocage, '  Encaisse deux fois ');

      expect(refus, isNull);
      final appel = serveur.posts.single;
      expect(appel.$1, '/sync-blocks/$blocage/decide');
      expect(appel.$2, {'decision': 'ABANDON', 'reason': 'Encaisse deux fois'});
      final b = (await db.watchTablettes().first).single.blocages.single;
      expect(b.decision, 'ABANDON');
      expect(b.motifDecision, 'Encaisse deux fois');
    });

    test('hors ligne ou refusee, elle se dit', () async {
      final depot = BlocagesRepository(db: db, api: serveur);
      serveur.horsLigne = true;
      expect(await depot.abandonner(blocage, 'Doublon'), contains('en ligne'));
      serveur.horsLigne = false;
      serveur.refus = const ApiException(
        ApiFailure.conflict,
        'Une saisie suivante en dépend.',
      );
      expect(
        await depot.abandonner(blocage, 'Doublon'),
        'Une saisie suivante en dépend.',
      );
      expect(
        (await db.select(db.syncBlocks).getSingle()).decision,
        isNull,
      );
    });
  });

  test('une tablette au schema 18 recoit les colonnes de l abandon', () async {
    await db.close();
    final dossier = await Directory.systemTemp.createTemp('atrium_');
    final fichier = File('${dossier.path}/atrium.sqlite');
    var base = AtriumDatabase(NativeDatabase(fichier));
    await base.customSelect('SELECT 1').get();
    for (final c in const [
      'abandonable',
      'abandon_note',
      'decision',
      'decision_reason',
      'decided_by',
      'decided_at',
    ]) {
      await base.customStatement('ALTER TABLE sync_blocks DROP COLUMN $c');
    }
    await base.customStatement(
      'ALTER TABLE block_reports DROP COLUMN abandonable',
    );
    await base.customStatement(
      'ALTER TABLE block_reports DROP COLUMN abandon_note',
    );
    await base.customStatement('PRAGMA user_version = 18');
    await base.close();

    base = AtriumDatabase(NativeDatabase(fichier));
    db = base;
    Future<Set<String>> colonnes(String table) async => {
      for (final l in await base.customSelect('PRAGMA table_info($table)').get())
        l.read<String>('name'),
    };
    expect(
      await colonnes('sync_blocks'),
      containsAll(['abandonable', 'decision', 'decided_by', 'decided_at']),
    );
    expect(
      await colonnes('block_reports'),
      containsAll(['abandonable', 'abandon_note']),
    );
    await dossier.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
