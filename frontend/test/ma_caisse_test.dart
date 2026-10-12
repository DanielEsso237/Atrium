/// Ma caisse : l'onglet Caisse de l'agent d'un point de vente.
///
/// Ce qui compte : le barman y voit son tiroir et ses versements, jamais
/// le montant des especes tant que le tiroir est ouvert (comptage a
/// l'aveugle) ; la reception n'a pas cet onglet, elle a la caisse du jour.
library;

import 'package:atrium/core/formats.dart';
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
import 'package:atrium/features/outlets/outlet_cash_screen.dart';
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

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    bar = (await OutletRepository(db).create(code: 'BAR', label: 'Bar')).id;
    final now = DateTime.now().toUtc();
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

    // Le tiroir ouvert : 1 500 en especes, 4 000 en mobile money.
    final ouvert = newId();
    await db.into(db.cashSessions).insert(
      CashSessionsCompanion.insert(
        id: ouvert, createdAt: now, updatedAt: now, hotelId: _hotel,
        userId: id, outletId: Value(bar),
        status: const Value(CashSessionStatus.OPEN),
        openedAt: Value(now), openingFloat: const Value(5000),
      ),
    );
    for (final (moyen, montant) in [
      (PaymentMethod.CASH, 1500),
      (PaymentMethod.MOBILE_MONEY, 4000),
    ]) {
      await db.into(db.payments).insert(
        PaymentsCompanion.insert(
          id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
          method: moyen, amount: montant, cashSessionId: Value(ouvert),
        ),
      );
    }
    // Hier : verse 11 500 pour 12 000 attendus, recu.
    final hier = now.subtract(const Duration(days: 1));
    await db.into(db.cashSessions).insert(
      CashSessionsCompanion.insert(
        id: newId(), createdAt: hier, updatedAt: hier, hotelId: _hotel,
        userId: id, outletId: Value(bar),
        status: const Value(CashSessionStatus.CLOSED),
        openedAt: Value(hier), closedAt: Value(hier),
        expectedAmount: const Value(12000),
        countedAmount: const Value(11500),
        variance: const Value(-500),
        receivedAt: Value(hier), receivedAmount: const Value(11500),
      ),
    );
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  Future<SessionState> sessionDe(WidgetTester tester, UserRow agent) async =>
      SessionState(
        agent: agent,
        acces: (await tester.runAsync(() => accessProfileFor(db, agent.id)))!,
      );

  test("l'onglet demande le droit de tenir une caisse", () {
    expect(permissionPour('/ma-caisse'), 'cash.session');
  });

  testWidgets('le barman voit son tiroir, pas ses especes', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = await sessionDe(tester, barman);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(() => _TestSession(session)),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const OutletCashScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Ouverte'), findsOneWidget);
    expect(find.textContaining('2 encaissements'), findsOneWidget);
    // Les especes : a compter, pas a lire. Le mobile money se montre.
    expect(find.text('à compter au versement'), findsOneWidget);
    expect(find.text(formatAmount(1500)), findsNothing);
    expect(find.text(formatAmount(4000)), findsOneWidget);
    // Le versement d'hier : declare, recu, et l'ecart constate.
    expect(find.textContaining('en attente'), findsNothing);
    expect(
      find.textContaining('versé ${formatAmount(11500)}'),
      findsOneWidget,
    );
    expect(find.text('−${formatAmount(500)}'), findsOneWidget);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("le barman a l'onglet, la reception non", (tester) async {
    final duBarman = destinationsPour(await sessionDe(tester, barman));
    final recep = await tester.runAsync(
      () => (db.select(db.users)..where((u) => u.employeeCode.equals('RECEP01')))
          .getSingle(),
    ) as UserRow;
    final deLaReception = destinationsPour(await sessionDe(tester, recep));

    expect(duBarman.map((d) => d.route), contains('/ma-caisse'));
    expect(deLaReception.map((d) => d.route), isNot(contains('/ma-caisse')));
  });
}
