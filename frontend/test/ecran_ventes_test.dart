/// L'ecran Ventes : le tableau de bord des points de vente.
///
/// Ce qui compte : l'agent du bar n'y voit que le bar, et tant que son
/// tiroir est ouvert il ne voit pas l'argent encaisse (comptage a
/// l'aveugle) -- il voit ce qu'il a servi.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/ids.dart';
import 'package:atrium/core/router.dart' show permissionPour;
import 'package:atrium/core/shell/app_shell.dart' show destinationsPour;
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/outlets/outlet_dashboard_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late UserRow barman;
  late String bar;
  late String resto;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    bar = (await OutletRepository(db).create(code: 'BAR', label: 'Bar')).id;
    resto = (await OutletRepository(db).create(code: 'REST2', label: 'Terrasse')).id;
    final now = DateTime.now().toUtc();

    // Le barman : role Points de vente, rattache au bar.
    final role = await (db.select(db.roles)
          ..where((r) => r.code.equals('RESTAURANT')))
        .getSingle();
    final id = newId();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
            employeeCode: 'BARMAN', firstName: 'Paul', lastName: 'Bar',
          ),
        );
    await db.into(db.userRoles).insert(
      UserRolesCompanion.insert(userId: id, roleId: role.id),
    );
    await db.into(db.userOutlets).insert(
      UserOutletsCompanion.insert(userId: id, outletId: bar),
    );
    barman = await (db.select(db.users)..where((u) => u.id.equals(id))).getSingle();

    // Une biere a 1 500 au bar, un plat a 9 000 en terrasse, aujourd'hui.
    for (final (point, label, prix) in [(bar, 'Biere', 1500), (resto, 'Plat', 9000)]) {
      final folio = newId();
      await db.into(db.folios).insert(
        FoliosCompanion.insert(
          id: folio, createdAt: now, updatedAt: now, hotelId: _hotel,
          number: 'FOL-$label', type: const Value(FolioType.WALK_IN),
        ),
      );
      await db.into(db.folioItems).insert(
        FolioItemsCompanion.insert(
          id: newId(), createdAt: now, updatedAt: now, folioId: folio,
          category: ChargeCategory.FNB, label: label,
          unitPrice: Value(prix), amount: Value(prix),
          businessDate: businessDateNow(),
          sourceTable: const Value('outlets'), sourceId: Value(point),
          postedAt: Value(now),
        ),
      );
    }
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  Future<void> ouvrirTiroir() => db.into(db.cashSessions).insert(
    CashSessionsCompanion.insert(
      id: newId(),
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
      hotelId: _hotel,
      userId: barman.id,
      status: const Value(CashSessionStatus.OPEN),
      openedAt: Value(DateTime.now().toUtc()),
      outletId: Value(bar),
    ),
  );

  Future<void> afficher(
    WidgetTester tester, {
    Size taille = const Size(1000, 1400),
  }) async {
    tester.view.physicalSize = taille;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final acces = (await tester.runAsync(() => accessProfileFor(db, barman.id)))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(
            () => _TestSession(SessionState(agent: barman, acces: acces)),
          ),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const OutletDashboardScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  }

  // Les flux de Drift laissent des minuteries : fermer la base, puis
  // demonter l'ecran, comme les autres tests d'ecran.
  Future<void> fermer(WidgetTester tester) async {
    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  }

  test("l'ecran Ventes demande le droit des commandes", () {
    expect(permissionPour('/ventes'), 'order.read');
  });

  testWidgets('le barman ne voit que le bar', (tester) async {
    await afficher(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Biere'), findsOneWidget);
    expect(find.text('Plat'), findsNothing);
    // Pas de filtre pour un seul point de vente.
    expect(find.text('Terrasse'), findsNothing);
    await fermer(tester);
  });

  testWidgets("tiroir ouvert, l'argent encaisse est masque", (tester) async {
    await tester.runAsync(ouvrirTiroir);
    await afficher(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Votre caisse est ouverte'), findsOneWidget);
    expect(find.text('Après le versement'), findsNWidgets(3));
    // Ce qu'il a servi reste visible.
    expect(find.text('Biere'), findsOneWidget);
    await fermer(tester);
  });

  testWidgets("sur un telephone, rien ne deborde, meme a l'aveugle", (
    tester,
  ) async {
    await tester.runAsync(ouvrirTiroir);
    await afficher(tester, taille: const Size(390, 844));

    expect(tester.takeException(), isNull);
    await fermer(tester);
  });

  testWidgets('sans tiroir ouvert, tout se voit', (tester) async {
    await afficher(tester);

    expect(find.textContaining('Votre caisse est ouverte'), findsNothing);
    expect(find.text('Après le versement'), findsNothing);
    await fermer(tester);
  });

  testWidgets('le menu du barman propose Ventes', (tester) async {
    final acces = (await tester.runAsync(() => accessProfileFor(db, barman.id)))!;
    final menu = destinationsPour(SessionState(agent: barman, acces: acces));

    expect(menu.map((d) => d.route), contains('/ventes'));
  });
}
