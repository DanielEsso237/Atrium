/// Une fiche ouverte au bar, le restaurant choisi dans la barre laterale :
/// la fiche se ferme et l'ecran passe au restaurant (16 octobre). Avant, la
/// fiche du bar restait par-dessus.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/orders/orders_screen.dart';
import 'package:atrium/features/orders/tableau_carte.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  testWidgets('choisir un autre point de vente ferme la fiche ouverte', (
    tester,
  ) async {
    final db = AtriumDatabase.memory();
    late UserRow agent;
    late AccessProfile acces;
    late OutletRow restau;
    await tester.runAsync(() async {
      await seedDemoData(db);
      await seedAccounts(db);
      agent = await (db.select(
        db.users,
      )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
      acces = (await accessProfileFor(db, agent.id))!;
      final points = OutletRepository(db);
      final bar = await points.create(code: 'BARX', label: 'Bar du test');
      // Rien ne se sert sans le tiroir ouvert du point de vente : sinon
      // « Nouveau client » propose d'abord d'ouvrir la caisse.
      await CashRepository(
        db,
      ).open(userId: agent.id, openingFloat: 0, outletId: bar.id);
      restau = await points.create(code: 'RESTX', label: 'Restau du test');
    });
    AtriumPalette.current = AtriumPalette.light;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(
            () => _Session(SessionState(agent: agent, acces: acces)),
          ),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const OrdersScreen()),
      ),
    );
    Future<void> attendre() async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    await attendre();
    await tester.tap(find.text('Bar du test'));
    await attendre();
    expect(find.text('Point de vente : Bar du test'), findsOneWidget);

    await tester.tap(find.text('Nouveau client').first);
    await attendre();
    expect(find.byType(TableauCarte), findsOneWidget);

    // Ce que fait la barre laterale : choisir le point de vente.
    final conteneur = ProviderScope.containerOf(
      tester.element(find.byType(OrdersScreen)),
    );
    conteneur.read(pointDeVenteChoisiProvider.notifier).choisir(restau.id);
    await attendre();

    expect(tester.takeException(), isNull);
    expect(find.byType(TableauCarte), findsNothing);
    expect(find.text('Point de vente : Restau du test'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
