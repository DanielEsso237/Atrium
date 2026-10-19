/// Les inventaires des donnees de test : trois magasins a trois moments du
/// comptage, ouverts par le depot -- donc par la file -- et une seule fois.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/donnees_de_test.dart';
import 'package:atrium/data/repositories/inventory_repository.dart';
import 'package:atrium/data/repositories/stock_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

const _hotel = InventoryRepository.defaultHotelId;

void main() {
  late AtriumDatabase db;
  late String admin;
  late Map<String, String> magasins;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    admin = (await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle()).id;

    final now = DateTime.now().toUtc();
    magasins = {};
    for (final (rang, code, libelle, central) in [
      (2, 'BAR', 'Bar', false),
      (1, 'ECONOMAT', 'Économat', true),
      (3, 'CUISINE', 'Cuisine', false),
      (4, 'BOUTIQUE', 'Boutique', false),
    ]) {
      final id = newId();
      magasins[code] = id;
      await db
          .into(db.stockLocations)
          .insert(
            StockLocationsCompanion.insert(
              id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
              code: code, label: libelle,
              sortOrder: Value(rang), isCentral: Value(central),
            ),
          );
    }
    final stocks = StockRepository(db);
    for (final (i, libelle) in [
      'Bière', 'Jus', 'Eau', 'Savon', 'Serviette', 'Riz', 'Huile', 'Sucre',
    ].indexed) {
      final produit = newId();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: produit, createdAt: now, updatedAt: now, hotelId: _hotel,
              reference: 'P$i', label: libelle,
            ),
          );
      await stocks.receive(
        placeId: magasins['ECONOMAT']!,
        productId: produit,
        quantity: 40 + i,
      );
      if (i < 3) {
        await stocks.receive(
          placeId: magasins['BAR']!,
          productId: produit,
          quantity: 12,
        );
      }
      if (i >= 5) {
        await stocks.receive(
          placeId: magasins['CUISINE']!,
          productId: produit,
          quantity: 8,
        );
      }
    }
  });

  tearDown(() => db.close());

  Future<Inventaire?> ouvert(String code) =>
      InventoryRepository(db).watchOuvert(magasins[code]!).first;

  test('trois magasins, trois moments du comptage', () async {
    final bilan = await chargerDonneesDeTest(
      db,
      agentId: admin,
      peut: (p) => p == 'stock.inventory',
    );
    expect(
      bilan,
      contains(
        'Inventaires ouverts : Économat compté aux deux tiers, '
        'Bar compté en entier, Cuisine à compter.',
      ),
    );

    // Le central d'abord : compte aux deux tiers, des manques et un surplus.
    final economat = (await ouvert('ECONOMAT'))!;
    expect(economat.lignes, hasLength(8));
    expect(economat.comptees, 6);
    expect(economat.ecarts.where((l) => l.ecart! < 0), isNotEmpty);
    expect(economat.ecarts.where((l) => l.ecart! > 0), isNotEmpty);

    final bar = (await ouvert('BAR'))!;
    expect(bar.comptees, bar.lignes.length);

    final cuisine = (await ouvert('CUISINE'))!;
    expect(cuisine.comptees, 0);

    // Un magasin sans stock n'a rien a compter.
    expect(await ouvert('BOUTIQUE'), isNull);

    // Le stock ne bouge pas : la theorique est ce qu'il dit encore.
    final lignes = await StockRepository(db)
        .watchLines(magasins['ECONOMAT']!)
        .first;
    expect(
      {for (final l in economat.lignes) l.productId: l.theorique},
      {for (final l in lignes) l.productId: l.quantity},
    );

    // Tout part dans la file : trois ouvertures, puis chaque comptage.
    final file = await db.select(db.outboxEntries).get();
    final envois = file.where((e) => e.entityTable == 'inventories');
    expect(envois, hasLength(3 + 6 + bar.lignes.length));

    // Une seconde fois : aucun inventaire de plus. (Sans point de vente ici,
    // le complement des rapports, lui, se rejoue.)
    expect(
      await chargerDonneesDeTest(
        db,
        agentId: admin,
        peut: (p) => p == 'stock.inventory',
      ),
      contains('Les inventaires de test sont déjà en cours.'),
    );
    expect(
      (await db.select(db.outboxEntries).get())
          .where((e) => e.entityTable == 'inventories'),
      hasLength(envois.length),
    );
  });

  test('sans le droit de compter, aucun inventaire', () async {
    await chargerDonneesDeTest(db, agentId: admin);
    expect(await ouvert('ECONOMAT'), isNull);
    expect(await db.select(db.inventories).get(), isEmpty);
  });
}
