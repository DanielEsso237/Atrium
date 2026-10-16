/// La barre laterale regroupee (16 octobre), sur le modele de Mouvements et
/// d'Entretien : Ventes range les points de vente et les services, Stocks
/// l'inventaire, Finances la caisse, les factures et les comptes. Un clic ouvre
/// l'entree, la fleche deplie ce qu'elle range.
library;

import 'package:atrium/core/shell/app_shell.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/dashboard_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/dashboard/dashboard_screen.dart'
    show dashboardProvider;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

List<Destination> _pour(Set<String> droits) =>
    destinationsPour(SessionState(acces: AccessProfile(permissions: droits)));

void main() {
  setUpAll(() async {
    for (final famille in {
      'Roboto': [
        for (final graisse in [400, 500, 600, 700, 800])
          'assets/fonts/roboto/Roboto-$graisse.ttf',
      ],
      'PhosphorLight': ['assets/fonts/phosphor/Phosphor-Light.ttf'],
      'PhosphorFill': ['assets/fonts/phosphor/Phosphor-Fill.ttf'],
    }.entries) {
      final police = FontLoader(famille.key);
      for (final fichier in famille.value) {
        police.addFont(rootBundle.load(fichier));
      }
      await police.load();
    }
  });

  test('les trois regroupements, et ce qui reste au premier niveau', () {
    final tout = _pour({
      'order.read',
      'stock.read',
      'stock.inventory',
      'accounting.read',
      'folio.read',
    });
    final parLibelle = {for (final d in tout) d.label: d};

    expect(parLibelle['Ventes']?.parent, isNull);
    expect(parLibelle['Points de vente']?.parent, '/ventes');
    expect(parLibelle['Services']?.parent, '/ventes');
    expect(parLibelle['Stocks']?.parent, isNull);
    expect(parLibelle['Inventaire']?.parent, '/stocks');
    expect(parLibelle['Finances']?.parent, isNull);
    for (final vue in [
      'Caisse du jour',
      'Factures',
      'Dépenses',
      'Comptabilité',
      'Rapports',
    ]) {
      expect(parLibelle[vue]?.parent, '/finances', reason: vue);
    }
    // Ce qui ne se regroupe pas reste au premier niveau.
    expect(parLibelle['Chambres']?.parent, isNull);

    // Chaque parent precede ce qu'il range.
    final routes = tout.map((d) => d.route).toList();
    expect(routes.indexOf('/ventes'), lessThan(routes.indexOf('/commandes')));
    expect(routes.indexOf('/stocks'), lessThan(routes.indexOf('/inventaire')));
    expect(routes.indexOf('/finances'), lessThan(routes.indexOf('/caisse')));
  });

  test('sans le parent, la sous-entree remonte au premier niveau', () {
    // Un comptoir qui sert sans tenir de caisse : ses factures, sans les
    // finances de l'hotel.
    final serveur = _pour({'order.read'});
    expect(serveur.map((d) => d.label), isNot(contains('Finances')));
    expect(serveur.firstWhere((d) => d.label == 'Factures').parent, isNull);

    // Le comptoir qui tient sa caisse : Finances range sa caisse et ses
    // factures, sans la caisse de l'hotel.
    final caissier = _pour({'order.read', 'cash.session'});
    final vues = [
      for (final d in caissier)
        if (d.parent == '/finances') d.label,
    ];
    expect(vues, ['Ma caisse', 'Factures']);

    // Qui compte un magasin sans lire le stock garde son inventaire.
    final compteur = _pour({'stock.inventory'});
    expect(compteur.firstWhere((d) => d.label == 'Inventaire').parent, isNull);
  });

  testWidgets(
    'Ventes deplie les points de vente, chacun deplie ses comptoirs',
    (tester) async {
      final db = AtriumDatabase.memory();
      late UserRow admin;
      late AccessProfile acces;
      await tester.runAsync(() async {
        await seedDemoData(db);
        await seedAccounts(db);
        admin = await (db.select(
          db.users,
        )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
        acces = await accessProfileFor(db, admin.id);
        final points = OutletRepository(db);
        await points.create(code: 'BARX', label: 'Bar du test');
        await points.create(code: 'RESTX', label: 'Restau du test');
      });
      AtriumPalette.current = AtriumPalette.light;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      GoRoute page(String chemin) => GoRoute(
        path: chemin,
        builder: (_, _) => Scaffold(body: Text('Page $chemin')),
      );
      final router = GoRouter(
        routes: [
          ShellRoute(
            builder: (context, state, child) =>
                AppShell(location: state.matchedLocation, child: child),
            routes: [
              for (final chemin in [
                '/',
                '/ventes',
                '/commandes',
                '/services',
                '/stocks',
                '/inventaire',
                '/finances',
                '/caisse',
                '/factures',
                '/comptabilite',
                '/depenses',
                '/rapports',
              ])
                page(chemin),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            sessionProvider.overrideWith(
              () => _Session(SessionState(agent: admin, acces: acces)),
            ),
            pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
            dashboardProvider.overrideWith(
              (ref) => Stream.value(
                const DashboardSummary(
                  chambresTotal: 10,
                  chambresOccupees: 2,
                  reservationsActives: 4,
                  arriveesDuJour: 1,
                  arriveesRestantes: 1,
                  departsDuJour: 2,
                  departsRestants: 2,
                  caDuJour: 0,
                  chambresANettoyer: 0,
                ),
              ),
            ),
          ],
          child: MaterialApp.router(
            theme: themeAtrium(),
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
          ),
        ),
      );
      Future<void> attendre() async {
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(milliseconds: 600));
        }
      }

      await attendre();
      // Replies : les entrees rangees ne se voient pas.
      expect(find.text('Ventes'), findsOneWidget);
      expect(find.text('Points de vente'), findsNothing);
      expect(find.text('Inventaire'), findsNothing);
      expect(find.text('Dépenses'), findsNothing);

      // Un clic sur Ventes ouvre son tableau de bord et le deplie.
      await tester.tap(find.text('Ventes'));
      await attendre();
      expect(find.text('Page /ventes'), findsOneWidget);
      expect(find.text('Points de vente'), findsOneWidget);
      expect(find.text('Services'), findsOneWidget);

      // Points de vente ouvre son ecran et deplie ses comptoirs.
      await tester.tap(find.text('Points de vente'));
      await attendre();
      expect(find.text('Page /commandes'), findsOneWidget);
      expect(find.text('Bar du test'), findsOneWidget);
      expect(find.text('Restau du test'), findsOneWidget);

      // Les fleches deplient Stocks et Comptabilité sans changer de page.
      // La barre defile : chaque fleche est amenee a l'ecran avant le geste.
      for (final fleche in ['Déplier stocks', 'Déplier finances']) {
        await tester.ensureVisible(find.byTooltip(fleche));
        await attendre();
        await tester.tap(find.byTooltip(fleche));
        await attendre();
      }
      expect(find.text('Page /commandes'), findsOneWidget);
      expect(find.text('Inventaire'), findsOneWidget);
      expect(find.text('Dépenses'), findsOneWidget);
      expect(find.text('Rapports'), findsOneWidget);

      await tester.ensureVisible(find.text('Inventaire'));
      await attendre();
      await tester.tap(find.text('Inventaire'));
      await attendre();
      expect(find.text('Page /inventaire'), findsOneWidget);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
  );
}
