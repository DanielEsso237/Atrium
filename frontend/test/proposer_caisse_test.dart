/// Caisse fermee : l'application propose de l'ouvrir, au lieu de refuser.
///
/// Retour du 23 octobre : « Ouvrir la caisse : l'appli doit proposer
/// d'ouvrir la caisse ». Rien ne se sert sans le tiroir ouvert du point de
/// vente (decision du 11 octobre) ; on le dit avant la commande, et on
/// l'ouvre d'un geste.
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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late UserRow agent;
  late OutletRow bar;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    agent = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    // Le bar, caisse fermee.
    bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  Future<void> attendre(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> ouvrirEcran(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final acces = (await tester.runAsync(
      () => accessProfileFor(db, agent.id),
    ))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(
            () => _TestSession(SessionState(agent: agent, acces: acces)),
          ),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const OrdersScreen()),
      ),
    );
    await attendre(tester);
  }

  Future<String?> tiroir(WidgetTester tester) async => tester.runAsync<String?>(
    () => CashRepository(db).openSessionId(agent.id, outletId: bar.id),
  );

  testWidgets('elle propose d ouvrir la caisse, puis la vente continue', (
    tester,
  ) async {
    await ouvrirEcran(tester);

    await tester.tap(find.text('Nouveau client'));
    await attendre(tester);
    expect(find.text('La caisse de Bar est fermée'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, '5000');
    await tester.tap(find.text('Ouvrir et continuer'));
    await attendre(tester);

    expect(tester.takeException(), isNull);
    expect(await tiroir(tester), isNotNull);
    // La fiche de vente s'ouvre aussitot : l'agent n'a pas a recommencer.
    expect(find.text('Consommation'), findsOneWidget);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sans ouvrir la caisse, rien ne se sert', (tester) async {
    await ouvrirEcran(tester);

    await tester.tap(find.text('Nouveau client'));
    await attendre(tester);
    await tester.tap(find.text('Annuler'));
    await attendre(tester);

    expect(await tiroir(tester), isNull);
    expect(find.text('Consommation'), findsNothing);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });
}
