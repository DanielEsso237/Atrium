/// L'onglet Personnel (15 octobre) : chaque agent, son role, ses points de
/// vente, et ce qu'il genere sur la periode.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/personnel_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/features/personnel/personnel_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  final jour = businessDayFor(DateTime.now());

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
  });

  tearDown(() => db.close());

  test('l ecran se construit', () {
    expect(const PersonnelScreen(), isA<PersonnelScreen>());
  });

  test('ce que chaque agent vend et encaisse, le meilleur d abord', () async {
    final bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    await CashRepository(
      db,
    ).open(userId: utilisateurDemo, openingFloat: 0, outletId: bar.id);
    await OrderRepository(db).sellWalkIn(
      outlet: bar,
      lines: const [('Biere', 1500, 2, null)],
      method: PaymentMethod.CASH,
      by: utilisateurDemo,
    );

    final agents = await db.watchPersonnel(du: jour, au: jour).first;

    final admin = agents.first;
    expect(admin.id, utilisateurDemo);
    expect(admin.chiffreAffaires, 3000);
    expect(admin.ventes, 1);
    expect(admin.encaisse, 3000);
    expect(admin.caisses, 1);
    expect(admin.roles, isNotEmpty);
    // Les autres comptes de demonstration n'ont rien vendu.
    expect(agents.skip(1).every((a) => a.chiffreAffaires == 0), isTrue);

    final parts = await db.watchPartsAgents(du: jour, au: jour).first;
    expect(parts[utilisateurDemo]!.single.libelle, 'Bar');
    expect(parts[utilisateurDemo]!.single.montant, 3000);

    // La veille : rien.
    final hier = DateTime(jour.year, jour.month, jour.day - 1);
    final avant = await db.watchPersonnel(du: hier, au: hier).first;
    expect(avant.every((a) => a.chiffreAffaires == 0), isTrue);
  });

  for (final largeur in [1280.0, 400.0]) {
    testWidgets("l'ecran s'affiche sans deborder ($largeur px)", (
      tester,
    ) async {
      final base = AtriumDatabase.memory();
      await tester.runAsync(() async {
        await seedDemoData(base);
        await seedAccounts(base);
      });
      AtriumPalette.current = AtriumPalette.light;
      tester.view.physicalSize = Size(largeur, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(base)],
          child: MaterialApp(
            theme: themeAtrium(),
            home: const PersonnelScreen(),
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump();
      }

      expect(tester.takeException(), isNull);
      expect(find.text('Personnel'), findsWidgets);
      expect(find.byType(ExpansionTile), findsWidgets);

      // La base est en memoire : pas de close, qui attendrait une lecture
      // en suspens dans le temps simule.
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
  }
}
