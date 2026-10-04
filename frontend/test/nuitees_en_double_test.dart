/// Une nuit n'est facturee qu'une fois, meme portee par deux tablettes.
///
/// Deux tablettes font le check-in du meme sejour : chacune porte ses nuits
/// sur son ardoise. Quand les ardoises se rejoignent (`adoptServerFolio`), la
/// nuit est la deux fois. Le serveur, qui tient le registre des nuits, n'en
/// garde qu'une et designe la sienne ; la tablette remplace sa copie.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:flutter_test/flutter_test.dart';

const _ardoiseServeur = '01920000-0000-7000-8000-00000000f001';

/// La nuit, telle que l'autre tablette l'a deja portee sur le serveur.
const _nuitServeur = '01920000-0000-7000-8000-00000000f101';

/// Un serveur qui a deja l'ardoise du sejour et sa nuit.
class _FauxApi extends ApiClient {
  _FauxApi() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final corps = <String, Map<String, Object?>>{};

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final b = (body as Map).cast<String, Object?>();
    corps[b['id'] as String? ?? path] = b;
    if (path.endsWith('/check-in')) return {'folio_id': _ardoiseServeur};
    if (path.endsWith('/items') && b['night_date'] != null) {
      return {'id': _nuitServeur};
    }
    return {'id': b['id']};
  }
}

void main() {
  late AtriumDatabase db;
  late GuestRepository guests;
  late ReservationRepository reservations;
  late FolioRepository folios;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    guests = GuestRepository(db);
    reservations = ReservationRepository(db);
    folios = FolioRepository(db);
  });

  tearDown(() => db.close());

  /// Un sejour d'une nuit arrive ici ; renvoie la ligne et l'ardoise locale.
  Future<(String, String)> arrivee() async {
    final client = await guests.create(firstName: 'Awa', lastName: 'Diallo');
    final chambre = await db
        .customSelect("SELECT id FROM rooms WHERE number = '101'")
        .getSingle();
    final resId = await reservations.create(
      guestId: client.id,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 2),
      nightlyRate: 25000,
      roomId: chambre.read<String>('id'),
    );
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(resId))).getSingle();
    await reservations.checkIn(lineId: ligne.id);
    return (ligne.id, (await folios.openFolioForStay(ligne.id))!.id);
  }

  /// L'ardoise du serveur, deja descendue, avec la nuit de l'autre tablette.
  Future<void> ardoiseServeurDescendue(String ligne) async {
    final now = DateTime.now().toUtc();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: _ardoiseServeur,
            createdAt: now,
            updatedAt: now,
            hotelId: '01920000-0000-7000-8000-000000000001',
            number: 'FOL-000015',
            reservationRoomId: Value(ligne),
            syncState: const Value(SyncState.synced),
          ),
        );
    await db
        .into(db.folioItems)
        .insert(
          FolioItemsCompanion.insert(
            id: _nuitServeur,
            createdAt: now,
            updatedAt: now,
            folioId: _ardoiseServeur,
            category: ChargeCategory.ROOM,
            label: 'Nuitee du 1 oct.',
            unitPrice: const Value(25000),
            amount: const Value(25000),
            businessDate: '2026-10-01',
            syncState: const Value(SyncState.synced),
          ),
        );
  }

  Future<FolioRow> ardoise(String id) =>
      (db.select(db.folios)..where((f) => f.id.equals(id))).getSingle();

  test('seule une nuitee part avec la date de sa nuit', () async {
    final (_, locale) = await arrivee();
    await folios.addCharge(
      folioId: locale,
      category: ChargeCategory.FNB,
      label: 'Cafe',
      unitPrice: 1500,
    );
    final api = _FauxApi();

    await OutboxSender(db: db, api: api).drain();

    final items = api.corps.values.where((b) => b.containsKey('category'));
    final nuit = items.singleWhere((b) => b['category'] == 'ROOM');
    final cafe = items.singleWhere((b) => b['category'] == 'FNB');
    expect(nuit['night_date'], '2026-10-01');
    expect(cafe.containsKey('night_date'), isFalse);
  });

  test('deux tablettes, une seule nuit facturee', () async {
    final (ligne, _) = await arrivee();
    await ardoiseServeurDescendue(ligne);

    await OutboxSender(db: db, api: _FauxApi()).drain();

    final nuits = await (db.select(db.folioItems)..where(
          (i) =>
              i.folioId.equals(_ardoiseServeur) &
              i.category.equalsValue(ChargeCategory.ROOM),
        ))
        .get();
    expect(nuits.map((n) => n.id), [_nuitServeur]);
    expect((await ardoise(_ardoiseServeur)).chargesTotal, 25000);
  });

  test('la nuit du serveur remplace la notre meme si elle n\'est pas '
      'descendue', () async {
    final (_, locale) = await arrivee();
    final nuitLocale = (await db.select(db.folioItems).get()).single;

    await folios.adoptServerCharge(
      localId: nuitLocale.id,
      serverId: _nuitServeur,
    );

    final items = await db.select(db.folioItems).get();
    expect(items.map((i) => i.id), [_nuitServeur]);
    expect(items.single.folioId, locale);
    expect((await ardoise(locale)).chargesTotal, 25000);
  });

  test('les ecritures qui visent notre nuit sont readressees', () async {
    await arrivee();
    final nuitLocale = (await db.select(db.folioItems).get()).single;

    await folios.adoptServerCharge(
      localId: nuitLocale.id,
      serverId: _nuitServeur,
    );

    final restantes = await (db.select(
      db.outboxEntries,
    )..where((e) => e.entityTable.equals('folio_items'))).get();
    expect(restantes.map((e) => e.entityId), everyElement(_nuitServeur));
    // Le corps garde son identifiant d'origine : c'est le renvoi, rejouable,
    // que le serveur reconnaitra.
    expect(
      restantes.map((e) => (jsonDecode(e.payload) as Map)['id']),
      everyElement(nuitLocale.id),
    );
  });
}
