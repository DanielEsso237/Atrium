/// Une vente fait baisser le stock du point de vente, tout de suite.
///
/// Deux bieres portees sur une chambre depuis le bar : le stock du bar perd
/// deux bieres sur la tablette, avant meme que la ligne remonte, et la ligne
/// part avec l'article et le point de vente pour que le serveur en fasse
/// autant. Pareil pour un client de passage. Un plat du jour ne touche a rien.
library;

import 'dart:convert';

import 'package:atrium/core/ids.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
// Importe pour verifier que l'ecran de saisie compile avec l'article vendu.
import 'package:atrium/features/orders/orders_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

void main() {
  late AtriumDatabase db;
  late OutletRow bar;
  late String magasinBar;
  late String biere;
  late String articleBiere;
  late String platDuJour;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    final now = DateTime.now().toUtc();
    magasinBar = newId();
    biere = newId();
    articleBiere = newId();
    platDuJour = newId();
    final categorie = newId();
    await db
        .into(db.stockLocations)
        .insert(
          StockLocationsCompanion.insert(
            id: magasinBar, createdAt: now, updatedAt: now, hotelId: _hotel,
            code: 'BAR', label: 'Bar', outletId: Value(bar.id),
          ),
        );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: biere, createdAt: now, updatedAt: now, hotelId: _hotel,
            reference: 'BIERE', label: 'Biere 65 cl',
          ),
        );
    await db
        .into(db.stockLevels)
        .insert(
          StockLevelsCompanion.insert(
            id: newId(), createdAt: now, updatedAt: now, productId: biere,
            stockLocationId: magasinBar, quantity: const Value(10),
          ),
        );
    await db
        .into(db.menuCategories)
        .insert(
          MenuCategoriesCompanion.insert(
            id: categorie, createdAt: now, updatedAt: now, hotelId: _hotel,
            label: 'Boissons', outletId: Value(bar.id),
          ),
        );
    await db
        .into(db.menuItems)
        .insert(
          MenuItemsCompanion.insert(
            id: articleBiere, createdAt: now, updatedAt: now, hotelId: _hotel,
            code: 'BIERE', label: 'Biere', menuCategoryId: categorie,
            price: const Value(1500), productId: Value(biere),
          ),
        );
    await db
        .into(db.menuItems)
        .insert(
          MenuItemsCompanion.insert(
            id: platDuJour, createdAt: now, updatedAt: now, hotelId: _hotel,
            code: 'PLAT', label: 'Plat du jour', menuCategoryId: categorie,
            price: const Value(4000),
          ),
        );
  });

  tearDown(() => db.close());

  Future<int> auBar() async => (await (db.select(
    db.stockLevels,
  )..where((l) => l.stockLocationId.equals(magasinBar))).getSingle()).quantity;

  Future<String> ardoise() async {
    final id = newId();
    final now = DateTime.now().toUtc();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
            number: 'FOL-T',
          ),
        );
    return id;
  }

  test('l ecran des points de vente se construit', () {
    expect(const OrdersScreen(), isA<OrdersScreen>());
  });

  test('portee sur une chambre, la biere sort du bar tout de suite', () async {
    final folio = await ardoise();
    await OrderRepository(db).charge(
      outlet: bar, folioId: folio, label: 'Biere', unitPrice: 1500,
      quantity: 2, menuItemId: articleBiere,
    );
    expect(await auBar(), 8);

    final p =
        jsonDecode((await db.select(db.outboxEntries).get()).last.payload)
            as Map;
    expect((p['menu_item_id'], p['source_id']), (articleBiere, bar.id));
  });

  test('un plat du jour ne touche a aucun stock', () async {
    final folio = await ardoise();
    await OrderRepository(db).charge(
      outlet: bar, folioId: folio, label: 'Plat du jour', unitPrice: 4000,
      menuItemId: platDuJour,
    );
    expect(await auBar(), 10);
  });

  test('un libelle saisi a la main ne sort rien', () async {
    final folio = await ardoise();
    await FolioRepository(db).addCharge(
      folioId: folio, category: ChargeCategory.FNB, label: 'Biere',
      unitPrice: 1500, sourceTable: 'outlets', sourceId: bar.id,
    );
    expect(await auBar(), 10);
  });

  test('le client de passage fait aussi sortir le stock', () async {
    // La vente tombe dans le tiroir de son point de vente.
    await CashRepository(
      db,
    ).open(userId: utilisateurDemo, openingFloat: 0, outletId: bar.id);
    await OrderRepository(db).sellWalkIn(
      outlet: bar,
      lines: [('Biere', 1500, 3, articleBiere)],
      method: PaymentMethod.CASH,
      by: utilisateurDemo,
    );
    expect(await auBar(), 7);
    final p =
        jsonDecode((await db.select(db.outboxEntries).get()).last.payload)
            as Map;
    expect((p['items'] as List).single['menu_item_id'], articleBiere);

    // Le serveur ne connait pas encore la vente : il dit toujours 10. La
    // descente n'efface pas les trois bieres vendues.
    final api = FakeCatalogApi(
      stockLevels: [
        RemoteStockLevel(productId: biere, locationId: magasinBar, quantity: 10),
      ],
    );
    await Descente(db, api, SyncRepository(db, api)).pull();
    expect(await auBar(), 7);
  });
}
