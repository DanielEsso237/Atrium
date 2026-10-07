import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/core/ui/atrium_ui.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/housekeeping_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/housekeeping/housekeeping_screen.dart';
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
  late HousekeepingRepository depot;
  late UserRow agent;
  late String roomId;
  late String taskId;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    depot = HousekeepingRepository(db);
    agent = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    roomId = (await (db.select(
      db.rooms,
    )..where((r) => r.number.equals('101'))).getSingle()).id;
    taskId = await depot.openTask(roomId: roomId, by: agent.id);
    AtriumPalette.current = AtriumPalette.light;
  });
  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  Future<void> attendre(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fermer(WidgetTester tester) async {
    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  Future<void> ouvrir(
    WidgetTester tester, {
    bool peutGerer = true,
    bool tactile = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SessionState(
      agent: agent,
      acces: peutGerer
          ? (await tester.runAsync(() => accessProfileFor(db, agent.id)))!
          : const AccessProfile(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(() => _TestSession(session)),
          housekeepingRepositoryProvider.overrideWithValue(depot),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(
          theme: themeAtrium().copyWith(
            platform: tactile ? TargetPlatform.android : TargetPlatform.linux,
          ),
          home: const HousekeepingScreen(),
        ),
      ),
    );
    await attendre(tester);
  }

  Future<void> deplacer(
    WidgetTester tester,
    HousekeepingStatus vers, {
    bool tactile = false,
  }) async {
    final geste = await tester.startGesture(tester.getCenter(find.text('101')));
    if (tactile) await tester.pump(const Duration(milliseconds: 600));
    await geste.moveBy(const Offset(20, 0));
    await tester.pump();
    final colonne = find.byKey(ValueKey('housekeeping-column-${vers.name}'));
    await geste.moveTo(tester.getTopLeft(colonne) + const Offset(80, 120));
    await tester.pump();
    await geste.up();
    await attendre(tester);
  }

  Future<HousekeepingStatus> etatChambre() async => (await (db.select(
    db.rooms,
  )..where((r) => r.id.equals(roomId))).getSingle()).housekeepingStatus;
  Future<HousekeepingTaskRow> tache() => (db.select(
    db.housekeepingTasks,
  )..where((t) => t.id.equals(taskId))).getSingle();
  Future<int> enFile() async => (await (db.select(
    db.outboxEntries,
  )..where((e) => e.entityTable.equals('housekeeping_tasks'))).get()).length;

  testWidgets(
    'les dépôts successifs nettoient la chambre et enfilent les deux actions',
    (tester) async {
      await ouvrir(tester);
      await deplacer(tester, HousekeepingStatus.IN_PROGRESS);
      expect(
        await tester.runAsync(etatChambre),
        HousekeepingStatus.IN_PROGRESS,
      );
      expect((await tester.runAsync(tache))!.assignedTo, agent.id);
      expect(await tester.runAsync(enFile), 2);
      await deplacer(tester, HousekeepingStatus.CLEAN);
      expect(await tester.runAsync(etatChambre), HousekeepingStatus.CLEAN);
      expect((await tester.runAsync(tache))!.status, TaskStatus.DONE);
      expect(await tester.runAsync(enFile), 3);
      expect(find.text('Fait'), findsWidgets);
      expect(tester.takeException(), isNull);
      await fermer(tester);
    },
  );

  testWidgets('le ménage se déplace aussi après un appui long tactile', (
    tester,
  ) async {
    await ouvrir(tester, tactile: true);
    await deplacer(tester, HousekeepingStatus.IN_PROGRESS, tactile: true);
    expect(await tester.runAsync(etatChambre), HousekeepingStatus.IN_PROGRESS);
    expect(await tester.runAsync(enFile), 2);
    expect(tester.takeException(), isNull);
    await fermer(tester);
  });

  testWidgets('Commencer fonctionne avec les droits locaux réels', (
    tester,
  ) async {
    await ouvrir(tester);
    await tester.tap(find.text('Commencer'));
    await attendre(tester);
    expect(await tester.runAsync(etatChambre), HousekeepingStatus.IN_PROGRESS);
    expect(find.text('Marquer terminée'), findsOneWidget);
    await tester.tap(find.text('Remettre à faire'));
    await attendre(tester);
    expect(await tester.runAsync(etatChambre), HousekeepingStatus.DIRTY);
    expect(find.text('Commencer'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await fermer(tester);
  });

  testWidgets(
    'une chambre faite revient dans les colonnes précédentes par dépôt',
    (tester) async {
      await tester.runAsync(() => depot.start(taskId, by: agent.id));
      await tester.runAsync(() => depot.finish(taskId, by: agent.id));
      await ouvrir(tester);
      await deplacer(tester, HousekeepingStatus.IN_PROGRESS);
      expect(
        await tester.runAsync(etatChambre),
        HousekeepingStatus.IN_PROGRESS,
      );
      expect((await tester.runAsync(tache))!.finishedAt, isNull);
      await deplacer(tester, HousekeepingStatus.DIRTY);
      expect(await tester.runAsync(etatChambre), HousekeepingStatus.DIRTY);
      expect((await tester.runAsync(tache))!.status, TaskStatus.PENDING);
      await deplacer(tester, HousekeepingStatus.IN_PROGRESS);
      expect(
        await tester.runAsync(etatChambre),
        HousekeepingStatus.IN_PROGRESS,
      );
      expect(tester.takeException(), isNull);
      await fermer(tester);
    },
  );

  testWidgets(
    'un dépôt ne saute pas le nettoyage et ne modifie pas sa propre colonne',
    (tester) async {
      await ouvrir(tester);
      await deplacer(tester, HousekeepingStatus.CLEAN);
      expect(await tester.runAsync(etatChambre), HousekeepingStatus.DIRTY);
      expect(await tester.runAsync(enFile), 1);
      await deplacer(tester, HousekeepingStatus.IN_PROGRESS);
      await deplacer(tester, HousekeepingStatus.IN_PROGRESS);
      expect(
        await tester.runAsync(etatChambre),
        HousekeepingStatus.IN_PROGRESS,
      );
      expect(await tester.runAsync(enFile), 2);
      await fermer(tester);
    },
  );

  testWidgets('sans droit de gestion le geste et le bouton restent inactifs', (
    tester,
  ) async {
    await ouvrir(tester, peutGerer: false);
    await deplacer(tester, HousekeepingStatus.IN_PROGRESS);
    expect(await tester.runAsync(etatChambre), HousekeepingStatus.DIRTY);
    expect(await tester.runAsync(enFile), 1);
    expect(
      tester
          .widget<PillButton>(find.widgetWithText(PillButton, 'Commencer'))
          .onPressed,
      isNull,
    );
    await fermer(tester);
  });
}
