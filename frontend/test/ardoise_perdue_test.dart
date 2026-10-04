/// Une ardoise que le serveur ne connait pas ne doit jamais bloquer la file.
///
/// Le cas vecu le 29 septembre : un sejour deja arrive sur le serveur recoit
/// le check-in de cette tablette. Le serveur garde son ardoise et ignore celle
/// de la tablette ; l'encaissement porte ensuite sur l'ardoise locale repondait
/// 404, et la file restait bloquee derriere lui. La tablette adopte desormais
/// l'ardoise que le serveur lui designe.
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
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// L'ardoise que le serveur a gardee pour ce sejour.
const _ardoiseServeur = '01920000-0000-7000-8000-00000000f001';

/// Un serveur qui repond au check-in avec sa propre ardoise.
class _FauxApi extends ApiClient {
  _FauxApi() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final chemins = <String>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    chemins.add(path);
    if (path.endsWith('/check-in')) return {'folio_id': _ardoiseServeur};
    return {};
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

  /// Un client arrive, une consommation et un encaissement partiel sur son
  /// ardoise locale. Renvoie la ligne de sejour et l'ardoise locale.
  Future<(String, String)> sejourAvecArdoise() async {
    final client = await guests.create(firstName: 'Awa', lastName: 'Diallo');
    final chambre = await db
        .customSelect(
          "SELECT id FROM rooms WHERE number = '101'",
        )
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

    final locale = (await folios.openFolioForStay(ligne.id))!;
    await folios.addCharge(
      folioId: locale.id,
      category: ChargeCategory.FNB,
      label: 'Cafe',
      unitPrice: 1500,
    );
    await folios.addPayment(
      folioId: locale.id,
      method: PaymentMethod.CASH,
      amount: 10000,
    );
    return (ligne.id, locale.id);
  }

  Future<List<FolioRow>> ardoisesDuSejour(String ligne) => (db.select(
    db.folios,
  )..where((f) => f.reservationRoomId.equals(ligne))).get();

  test('tout passe sur l\'ardoise du serveur, il n\'en reste qu\'une', () async {
    final (ligne, locale) = await sejourAvecArdoise();
    final avant = (await folios.openFolioForStay(ligne))!;

    await folios.adoptServerFolio(localId: locale, serverId: _ardoiseServeur);

    final ardoises = await ardoisesDuSejour(ligne);
    expect(ardoises.map((f) => f.id), [_ardoiseServeur]);
    // Nuitee + cafe, moins l'encaissement : le solde n'a pas bouge.
    expect(ardoises.single.balance, avant.balance);
    expect(ardoises.single.chargesTotal, 25000 + 1500);
    expect(ardoises.single.paymentsTotal, 10000);

    final items = await db.select(db.folioItems).get();
    expect(items.map((i) => i.folioId).toSet(), {_ardoiseServeur});
    final paiements = await db.select(db.payments).get();
    expect(paiements.single.folioId, _ardoiseServeur);
  });

  test('les ecritures en attente sont readressees', () async {
    final (_, locale) = await sejourAvecArdoise();

    await folios.adoptServerFolio(localId: locale, serverId: _ardoiseServeur);

    final restantes = await (db.select(
      db.outboxEntries,
    )..where((e) => e.status.equalsValue(OutboxStatus.PENDING))).get();
    final adresses = restantes
        .map((e) => (jsonDecode(e.payload) as Map)['folio_id'])
        .whereType<String>()
        .toSet();
    expect(adresses, isNot(contains(locale)));
    expect(adresses, contains(_ardoiseServeur));
  });

  test('l\'ardoise du serveur deja descendue est completee, pas doublee',
      () async {
    final (ligne, locale) = await sejourAvecArdoise();
    // La descente a deja rapatrie l'ardoise du serveur, avec sa propre ligne.
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
    await folios.addCharge(
      folioId: _ardoiseServeur,
      category: ChargeCategory.FNB,
      label: 'Eau',
      unitPrice: 500,
    );

    await folios.adoptServerFolio(localId: locale, serverId: _ardoiseServeur);

    final ardoises = await ardoisesDuSejour(ligne);
    expect(ardoises.map((f) => f.id), [_ardoiseServeur]);
    expect(ardoises.single.number, 'FOL-000015');
    expect(ardoises.single.chargesTotal, 25000 + 1500 + 500);
  });

  test('apres le check-in, la file part vers l\'ardoise du serveur', () async {
    final (_, locale) = await sejourAvecArdoise();
    final api = _FauxApi();

    final rapport = await OutboxSender(db: db, api: api).drain();

    expect(rapport.arret, DrainStop.termine);
    final versArdoises = api.chemins.where((c) => c.startsWith('/folios/'));
    expect(versArdoises, isNotEmpty);
    expect(versArdoises.every((c) => c.startsWith('/folios/$_ardoiseServeur/')),
        isTrue);
    expect(api.chemins.any((c) => c.contains(locale)), isFalse);
  });

  test('un check-in qui garde l\'ardoise de la tablette ne change rien',
      () async {
    final (ligne, locale) = await sejourAvecArdoise();

    await folios.adoptServerFolio(localId: locale, serverId: locale);

    expect((await ardoisesDuSejour(ligne)).map((f) => f.id), [locale]);
  });
}
