/// Les gestes de stock sur la tablette.
///
/// L'economat recoit 48 bieres ; le bar en demande 24 ; le controleur valide :
/// l'economat en a 24, le bar 24. Un transfert refuse ne bouge rien. Chaque
/// geste part dans la file, sous la forme que le serveur attend.
library;

import 'dart:convert';

import 'package:atrium/core/ids.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/repositories/stock_repository.dart';
// Importe pour verifier que l'ecran compile avec le reste.
import 'package:atrium/features/stock/stock_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

void main() {
  late AtriumDatabase db;
  late StockRepository stocks;
  late String economat;
  late String bar;
  late String biere;

  setUp(() async {
    db = AtriumDatabase.memory();
    stocks = StockRepository(db);
    final now = DateTime.now().toUtc();
    economat = newId();
    bar = newId();
    biere = newId();
    await db
        .into(db.stockLocations)
        .insert(
          StockLocationsCompanion.insert(
            id: economat, createdAt: now, updatedAt: now, hotelId: _hotel,
            code: 'ECONOMAT', label: 'Économat', isCentral: const Value(true),
          ),
        );
    await db
        .into(db.stockLocations)
        .insert(
          StockLocationsCompanion.insert(
            id: bar, createdAt: now, updatedAt: now, hotelId: _hotel,
            code: 'BAR', label: 'Bar', sortOrder: const Value(1),
          ),
        );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: biere, createdAt: now, updatedAt: now, hotelId: _hotel,
            reference: 'BIERE', label: 'Biere 65 cl', minStock: const Value(30),
          ),
        );
  });

  tearDown(() => db.close());

  Future<int> qte(String magasin) async =>
      (await stocks.watchLines(magasin, allProducts: true).first)
          .firstWhere((l) => l.productId == biere)
          .quantity;

  Future<Map> dernierEnvoi() async =>
      jsonDecode((await db.select(db.outboxEntries).get()).last.payload) as Map;

  test('l ecran se construit', () {
    expect(const StockScreen(), isA<StockScreen>());
  });

  test('une entree a l economat compte, et part avec son id', () async {
    final id = await stocks.receive(
      placeId: economat, productId: biere, quantity: 48, unitCost: 600,
    );
    expect(await qte(economat), 48);
    final p = await dernierEnvoi();
    expect((p['id'], p['type'], p['quantity'], p['unit_cost']), (id, 'IN', 48, 600));
  });

  test('un transfert attend : rien ne bouge avant la validation', () async {
    await stocks.receive(placeId: economat, productId: biere, quantity: 48);
    final t = await stocks.requestTransfer(
      fromPlaceId: economat, toPlaceId: bar, productId: biere, quantity: 24,
    );
    expect(await qte(economat), 48);
    expect(await qte(bar), 0);
    final attente = await stocks.watchPendingTransfers().first;
    expect(attente.single.id, t);
    expect((attente.single.fromLabel, attente.single.toLabel), ('Économat', 'Bar'));

    await stocks.approve(t, note: 'OK');
    expect(await qte(economat), 24);
    expect(await qte(bar), 24);
    expect(await stocks.watchPendingTransfers().first, isEmpty);
    final p = await dernierEnvoi();
    expect((p['id'], p['action'], p['note']), (t, 'APPROVE', 'OK'));
  });

  test('un transfert refuse ne bouge rien, et ne se valide plus', () async {
    final t = await stocks.requestTransfer(
      fromPlaceId: economat, toPlaceId: bar, productId: biere, quantity: 5,
    );
    await stocks.reject(t, note: 'Le bar en a encore');
    expect(await qte(bar), 0);
    expect((await dernierEnvoi())['action'], 'REJECT');
    await expectLater(stocks.approve(t), throwsStateError);
  });

  test('celui qui demande un transfert ne le valide pas lui-meme', () async {
    // Le serveur le refuse ; un refus par la file la bloquerait. La tablette
    // refuse donc avant d'ecrire, avec les memes mots.
    await stocks.receive(placeId: economat, productId: biere, quantity: 48);
    final t = await stocks.requestTransfer(
      fromPlaceId: economat, toPlaceId: bar, productId: biere, quantity: 24,
      by: 'econome',
    );
    final enFile = (await db.select(db.outboxEntries).get()).length;

    await expectLater(
      stocks.approve(t, by: 'econome'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('ne peut pas le valider lui-même'),
        ),
      ),
    );
    // Rien n'a bouge, rien n'est parti, et le transfert attend toujours.
    expect(await qte(bar), 0);
    expect((await db.select(db.outboxEntries).get()).length, enFile);
    expect((await stocks.watchPendingTransfers().first).single.id, t);

    // Un autre que lui valide, et le stock bouge.
    await stocks.approve(t, by: 'controleur');
    expect(await qte(economat), 24);
    expect(await qte(bar), 24);
    final m = await (db.select(
      db.stockMovements,
    )..where((x) => x.id.equals(t))).getSingle();
    expect((m.movedBy, m.decidedBy), ('econome', 'controleur'));
  });

  test('le demandeur peut retirer sa propre demande', () async {
    // Refuser ne fait rien bouger : le serveur ne l'interdit pas, la
    // tablette non plus.
    final t = await stocks.requestTransfer(
      fromPlaceId: economat, toPlaceId: bar, productId: biere, quantity: 5,
      by: 'econome',
    );
    await stocks.reject(t, by: 'econome');
    expect(await stocks.watchPendingTransfers().first, isEmpty);
  });

  test('le stock bas et le stock negatif se voient', () async {
    await stocks.receive(placeId: economat, productId: biere, quantity: 10);
    var ligne = (await stocks.watchLines(economat, allProducts: true).first).single;
    expect((ligne.isLow, ligne.isNegative), (true, false));

    // Un transfert valide au-dela du stock : permis, et visible.
    final t = await stocks.requestTransfer(
      fromPlaceId: economat, toPlaceId: bar, productId: biere, quantity: 12,
    );
    await stocks.approve(t);
    ligne = (await stocks.watchLines(economat, allProducts: true).first).single;
    expect((ligne.quantity, ligne.isNegative), (-2, true));
  });

  test('les refus du serveur sont faits avant d ecrire', () async {
    await expectLater(
      stocks.requestTransfer(
        fromPlaceId: bar, toPlaceId: bar, productId: biere, quantity: 1,
      ),
      throwsStateError,
    );
    await expectLater(
      stocks.receive(placeId: economat, productId: biere, quantity: 0),
      throwsStateError,
    );
    expect(await db.select(db.outboxEntries).get(), isEmpty);
  });

  test('le barman ne voit que le stock de ses points de vente', () async {
    final now = DateTime.now().toUtc();
    final outlet = newId();
    final barman = newId();
    await db
        .into(db.outlets)
        .insert(
          OutletsCompanion.insert(
            id: outlet, createdAt: now, updatedAt: now, hotelId: _hotel,
            code: 'BAR', label: 'Bar',
          ),
        );
    await (db.update(db.stockLocations)..where((m) => m.id.equals(bar))).write(
      StockLocationsCompanion(outletId: Value(outlet)),
    );
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: barman, createdAt: now, updatedAt: now, hotelId: _hotel,
            employeeCode: 'BAR01', firstName: 'Ines', lastName: 'Mbarga',
          ),
        );
    await db
        .into(db.userOutlets)
        .insert(UserOutletsCompanion.insert(userId: barman, outletId: outlet));

    final siens = await stocks.watchPlaces(agentId: barman).first;
    expect(siens.map((m) => m.label), ['Bar']);
    // L'administration, sans rattachement, voit tout.
    final tous = await stocks.watchPlaces().first;
    expect(tous.map((m) => m.label), ['Économat', 'Bar']);
  });

  test('les mouvements remontent dans la file des stocks', () async {
    await stocks.receive(placeId: economat, productId: biere, quantity: 1);
    final e = (await db.select(db.outboxEntries).get()).single;
    expect((e.entityTable, e.op), ('stock_movements', SyncOp.INSERT));
  });
}
