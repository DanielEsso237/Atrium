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
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/outlet_tab_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
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
    bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
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

  testWidgets('le client loge n a qu une tuile, celle de sa chambre', (
    tester,
  ) async {
    // Retours des 23 et 24 octobre : son ardoise du bar faisait une seconde
    // tuile, et il passait pour un client de passage.
    await tester.runAsync(() async {
      final client = await GuestRepository(
        db,
      ).create(firstName: 'Awa', lastName: 'Diallo');
      final chambre = await (db.select(
        db.rooms,
      )..where((r) => r.number.equals('101'))).getSingle();
      final reservations = ReservationRepository(db);
      final dossier = await reservations.create(
        guestId: client.id,
        roomTypeId: chambre.roomTypeId,
        arrival: DateTime.now().subtract(const Duration(days: 1)),
        departure: DateTime.now().add(const Duration(days: 2)),
        nightlyRate: 25000,
        roomId: chambre.id,
      );
      final ligne = await (db.select(
        db.reservationRooms,
      )..where((l) => l.reservationId.equals(dossier))).getSingle();
      await reservations.checkIn(lineId: ligne.id);
      final ardoises = OutletTabRepository(db);
      final id = await ardoises.ouvrir(
        pointDeVente: bar,
        by: agent.id,
        guestId: client.id,
      );
      await ardoises.servir(
        pointDeVente: bar,
        ardoiseId: id,
        libelle: 'Coca',
        prixUnitaire: 700,
        by: agent.id,
        categorie: ChargeCategory.FNB,
      );
    });
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
    await attendre(tester);

    expect(tester.takeException(), isNull);
    // Sa chambre porte ce qu'il doit ici ; plus de tuile a part a son nom.
    expect(find.textContaining('À payer ici : 700'), findsOneWidget);
    expect(find.text('101 · Awa Diallo'), findsNothing);

    // Toucher sa chambre ouvre son ardoise, pour la regler en partant.
    await tester.tap(find.textContaining('À payer ici'));
    await attendre(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('1 × Coca'), findsOneWidget);
    expect(find.textContaining('Payer '), findsOneWidget);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });
}
