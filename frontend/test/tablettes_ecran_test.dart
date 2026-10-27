/// L'ecran Tablettes : quelle tablette est bloquee, sur quoi, de qui.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/blocages_repository.dart';
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

/// Le serveur accepte la decision : elle s'ecrit ici comme il la rendrait.
class _DepotAccepte extends BlocagesRepository {
  _DepotAccepte(AtriumDatabase db)
    : super(
        db: db,
        api: ApiClient(baseUrl: 'http://localhost', tokens: const TokenStore()),
      );

  final motifs = <String>[];

  @override
  Future<String?> abandonner(String blocageId, String motif) async {
    motifs.add(motif);
    await (db.update(db.syncBlocks)..where((b) => b.id.equals(blocageId)))
        .write(
          SyncBlocksCompanion(
            decision: const Value('ABANDON'),
            decisionReason: Value(motif),
          ),
        );
    return null;
  }
}

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
            abandonable: const Value(true),
          ),
        );
    AtriumPalette.current = AtriumPalette.light;
  });

  // Pas de `db.close` : la fermeture attend sans fin une lecture en suspens
  // de l'ecran.

  Future<void> laisserLire(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> afficher(WidgetTester tester, {BlocagesRepository? depot}) async {
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
          if (depot != null) blocagesRepositoryProvider.overrideWithValue(depot),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const TablettesScreen()),
      ),
    );
    await laisserLire(tester);
  }

  Future<void> demonter(WidgetTester tester) async {
    // L'alerte de la tablette bloquee garde un minuteur de rappel.
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('la tablette bloquee, sa saisie et son agent', (tester) async {
    await afficher(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Réception 1'), findsOneWidget);
    expect(find.text('Bloquée'), findsOneWidget);
    expect(find.textContaining('Encaissement'), findsOneWidget);
    expect(find.textContaining('saisi par RECEP01'), findsOneWidget);
    expect(find.textContaining('2 saisies attendent derrière'), findsOneWidget);
    expect(find.text('Abandonner cette saisie'), findsOneWidget);

    await demonter(tester);
  });

  testWidgets('abandonner : motif obligatoire, puis la decision attend la '
      'tablette', (tester) async {
    final depot = _DepotAccepte(db);
    await afficher(tester, depot: depot);

    await tester.tap(find.text('Abandonner cette saisie'));
    await tester.pumpAndSettle();
    final confirmer = find.widgetWithText(FilledButton, 'Abandonner');
    expect(tester.widget<FilledButton>(confirmer).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Encaissé deux fois');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirmer).onPressed, isNotNull);
    await tester.tap(confirmer);
    await tester.pumpAndSettle();
    await laisserLire(tester);

    expect(depot.motifs, ['Encaissé deux fois']);
    expect(find.text('Abandonner cette saisie'), findsNothing);
    expect(
      find.textContaining('Abandon demandé : « Encaissé deux fois »'),
      findsOneWidget,
    );
    expect(find.textContaining('prochain échange'), findsOneWidget);

    await demonter(tester);
  });

  testWidgets('ce que la tablette refuse : pas de bouton, la note', (
    tester,
  ) async {
    await (db.update(db.syncBlocks)).write(
      const SyncBlocksCompanion(
        abandonable: Value(false),
        abandonNote: Value('Une saisie suivante en dépend.'),
      ),
    );
    await afficher(tester);

    expect(find.text('Abandonner cette saisie'), findsNothing);
    expect(find.text('Une saisie suivante en dépend.'), findsOneWidget);

    await demonter(tester);
  });
}
