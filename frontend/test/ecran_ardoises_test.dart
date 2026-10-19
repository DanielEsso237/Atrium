/// L'ecran Commandes montre les ardoises du comptoir.
///
/// Decision du 12 octobre : une tuile par ardoise (« Client divers n°1 »), ce qui
/// reste a payer, et sa fiche avec les gestes. Les filtres : en cours, non
/// payees (par defaut) ; payees aujourd'hui ; toutes.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/outlet_tab_repository.dart';
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

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    agent = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    final bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    await CashRepository(
      db,
    ).open(userId: agent.id, openingFloat: 0, outletId: bar.id);
    final ardoises = OutletTabRepository(db);
    final id = await ardoises.ouvrir(pointDeVente: bar, by: agent.id);
    await ardoises.servir(
      pointDeVente: bar,
      ardoiseId: id,
      libelle: 'Biere',
      prixUnitaire: 1500,
      by: agent.id,
      categorie: ChargeCategory.FNB,
    );
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  Future<void> attendre(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('la tuile de l ardoise, puis sa fiche', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final acces = (await tester.runAsync(() => accessProfileFor(db, agent.id)))!;

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
    // Le bar, seul point de vente : il s'ouvre d'emblee, sans menu a
    // derouler (18 octobre).
    await attendre(tester);

    expect(tester.takeException(), isNull);
    // La tuile, et la meme ardoise dans les dernieres ventes en dessous
    // (15 octobre) : la tuile vient d'abord.
    expect(find.text('Client divers n°1'), findsNWidgets(2));
    expect(find.text('À payer'), findsNWidgets(2));
    expect(find.text('En cours, non payées'), findsOneWidget);

    await tester.tap(find.text('Client divers n°1').first);
    await attendre(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('1 × Biere'), findsOneWidget);
    expect(find.textContaining('Payer '), findsOneWidget);
    expect(find.text('Ajouter'), findsOneWidget);
    // Renommer : l'etiquette sur la photo, et le bouton dans les actions.
    expect(find.byTooltip('Nommer l’ardoise'), findsOneWidget);
    expect(find.text('Renommer'), findsOneWidget);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });
}
