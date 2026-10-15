/// L'ecran Comptabilite (ticket D8) : les memes chiffres que les routes
/// `/accounting/*` du serveur, calcules sur la base locale.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/compta_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/accounting/accounting_screen.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

const _biere = '01920000-0000-7000-8000-00000000b1e0';
const _savon = '01920000-0000-7000-8000-00000000500a';
const _economat = '01920000-0000-7000-8000-0000000ec0a7';

void main() {
  late AtriumDatabase db;
  late OutletRow bar;
  final jour = businessDayFor(DateTime.now());

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    await CashRepository(
      db,
    ).open(userId: utilisateurDemo, openingFloat: 0, outletId: bar.id);
    final t0 = DateTime.utc(2026, 10, 1);
    final hotel = bar.hotelId;

    // La biere : achetee 600, livree depuis au cout moyen de 500.
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: _biere,
            createdAt: t0,
            updatedAt: t0,
            hotelId: hotel,
            reference: 'BIE',
            label: 'Bière',
            purchasePrice: const Value(600),
            averageCost: const Value(500),
            salePrice: const Value(1500),
          ),
        );
    // Le savon ne se vend pas, et aucune livraison n'a dit son prix.
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: _savon,
            createdAt: t0,
            updatedAt: t0,
            hotelId: hotel,
            reference: 'SAV',
            label: 'Savon',
            purchasePrice: const Value(250),
          ),
        );
    const categorie = '01920000-0000-7000-8000-0000000ca7e0';
    await db
        .into(db.menuCategories)
        .insert(
          MenuCategoriesCompanion.insert(
            id: categorie,
            createdAt: t0,
            updatedAt: t0,
            hotelId: hotel,
            label: 'Boissons',
            outletId: Value(bar.id),
          ),
        );
    await db
        .into(db.menuItems)
        .insert(
          MenuItemsCompanion.insert(
            id: '01920000-0000-7000-8000-0000000a271c',
            createdAt: t0,
            updatedAt: t0,
            hotelId: hotel,
            code: 'BIE',
            label: 'Bière',
            menuCategoryId: categorie,
            price: const Value(1500),
            productId: const Value(_biere),
          ),
        );

    await db
        .into(db.stockLocations)
        .insert(
          StockLocationsCompanion.insert(
            id: _economat,
            createdAt: t0,
            updatedAt: t0,
            hotelId: hotel,
            code: 'ECO',
            label: 'Économat',
            isCentral: const Value(true),
          ),
        );
    Future<void> niveau(String id, String produit, int quantite) => db
        .into(db.stockLevels)
        .insert(
          StockLevelsCompanion.insert(
            id: id,
            createdAt: t0,
            updatedAt: t0,
            productId: produit,
            stockLocationId: _economat,
            quantity: Value(quantite),
          ),
        );
    await niveau('01920000-0000-7000-8000-0000000e0001', _biere, 10);
    // Un stock negatif vaut zero : un comptage en retard, pas une dette.
    await niveau('01920000-0000-7000-8000-0000000e0002', _savon, -3);
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  for (final largeur in [1280.0, 400.0]) {
    testWidgets('l ecran s affiche sans debordement ($largeur px)', (
      tester,
    ) async {
      AtriumPalette.current = AtriumPalette.light;
      tester.view.physicalSize = Size(largeur, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final agent = await tester.runAsync(
        () => (db.select(
          db.users,
        )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle(),
      );
      final acces = (await tester.runAsync(
        () => accessProfileFor(db, agent!.id),
      ))!;
      await tester.runAsync(
        () => OrderRepository(db).sellWalkIn(
          outlet: bar,
          lines: const [('Bière', 1500, 2, null)],
          method: PaymentMethod.CASH,
          by: utilisateurDemo,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            sessionProvider.overrideWith(
              () => _TestSession(SessionState(agent: agent, acces: acces)),
            ),
            pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
          ],
          child: MaterialApp(
            theme: themeAtrium(),
            home: const AccountingScreen(),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Comptabilité'), findsWidgets);
      expect(find.text('Bar'), findsOneWidget);
      expect(find.text('Économat'), findsOneWidget);

      await tester.tap(find.text('Bar'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('la marge du bar : la biere a son cout, le plat du jour reste a part',
      () async {
    await OrderRepository(db).sellWalkIn(
      outlet: bar,
      lines: const [('Bière', 1500, 2, null), ('Plat du jour', 3000, 1, null)],
      method: PaymentMethod.CASH,
      by: utilisateurDemo,
    );

    final marges = await db
        .watchMargesPointsDeVente(du: jour, au: jour)
        .first;

    expect(marges, hasLength(1));
    final m = marges.single;
    expect(m.libelle, 'Bar');
    expect(m.recette, 6000);
    expect(m.sansCout, 3000);
    expect(m.cout, 1000); // 2 x 500, le cout moyen, pas le prix d'achat
    expect(m.marge, 2000);
    expect(m.tauxBp, 6667);
    expect(
      m.articles.firstWhere((a) => a.libelle == 'Plat du jour').cout,
      isNull,
    );

    // La veille : rien.
    final hier = DateTime(jour.year, jour.month, jour.day - 1);
    expect(
      await db.watchMargesPointsDeVente(du: hier, au: hier).first,
      isEmpty,
    );
  });

  test('la marge d une unite : cout moyen, sinon prix d achat', () async {
    final produits = await db.watchMargesProduits().first;
    final biere = produits.firstWhere((p) => p.id == _biere);
    expect(biere.cout, 500);
    expect(biere.marge, 1000);
    expect(biere.tauxBp, 6667);
    final savon = produits.firstWhere((p) => p.id == _savon);
    expect(savon.cout, 250);
    expect(savon.tauxBp, isNull);
  });

  test('la valeur du stock : l economat d abord, le negatif vaut zero',
      () async {
    final magasins = await db.watchValeurStock().first;
    expect(magasins.first.id, _economat);
    expect(magasins.first.lignes, hasLength(1));
    expect(magasins.first.valeur, 5000);
  });
}
