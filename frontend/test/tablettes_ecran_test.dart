/// L'ecran Tablettes : quelle tablette est bloquee, sur quoi, de qui.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/alerts/alert_signal.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/sync/tablettes_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/signal_silencieux.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _tablette = '01920000-0000-7000-8000-00000000ab12';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late UserRow admin;
  late UserRow recep;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    admin = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    recep = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('RECEP01'))).getSingle();
    final now = DateTime.utc(2026, 10, 26, 8);
    await db
        .into(db.devices)
        .insert(
          DevicesCompanion.insert(
            id: _tablette,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            deviceUid: _tablette,
            name: 'Réception 1',
            lastSeenAt: Value(now),
          ),
        );
    await db
        .into(db.syncBlocks)
        .insert(
          SyncBlocksCompanion.insert(
            id: '01920000-0000-7000-8000-00000000bb01',
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            deviceId: _tablette,
            authorId: Value(recep.id),
            entityTable: 'payments',
            entityId: '01920000-0000-7000-8000-00000000b001',
            operation: 'INSERT',
            payload: const Value('{"amount": 15000}'),
            reason: const Value('Ce folio est deja solde.'),
            blockedAt: now,
            reportedAt: now,
            pendingBehind: const Value(2),
          ),
        );
    AtriumPalette.current = AtriumPalette.light;
  });

  // Pas de `db.close` : la fermeture attend sans fin une lecture en suspens
  // de l'ecran.

  testWidgets('la tablette bloquee, sa saisie et son agent', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final acces = (await tester.runAsync(() => accessProfileFor(db, admin.id)))!;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(
            () => _TestSession(SessionState(agent: admin, acces: acces)),
          ),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
          // L'alerte « Tablette bloquee » sonnerait : pas de son en test.
          signalAlerteProvider.overrideWithValue(SignalSilencieux()),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const TablettesScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Réception 1'), findsOneWidget);
    expect(find.text('Bloquée'), findsOneWidget);
    expect(find.textContaining('Encaissement'), findsOneWidget);
    expect(find.textContaining('saisi par RECEP01'), findsOneWidget);
    expect(find.textContaining('2 saisies attendent derrière'), findsOneWidget);
    expect(acces.peut('sync.monitor'), isTrue);

    // Demonter : l'alerte de la tablette bloquee garde un minuteur de rappel.
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
