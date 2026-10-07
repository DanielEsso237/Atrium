import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/core/ui/atrium_ui.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/housekeeping_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/rooms/room_board_screen.dart';
import 'package:atrium/features/rooms/room_cleaning_dialog.dart';
import 'package:drift/drift.dart' show Value, DatabaseConnection;
import 'package:drift/native.dart';
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
  late SessionState session;
  late HousekeepingRepository depot;
  late String first;
  late String second;

  setUp(() async {
    // La fermeture immediate des flux evite les minuteurs de cache Drift
    // dans l'horloge simulee de WidgetTester.
    db = AtriumDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    await seedDemoData(db);
    await seedAccounts(db);
    final user = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('RECEP01'))).getSingle();
    session = SessionState(
      agent: user,
      acces: await accessProfileFor(db, user.id),
    );
    depot = HousekeepingRepository(db);
    first = (await (db.select(
      db.rooms,
    )..where((r) => r.number.equals('101'))).getSingle()).id;
    second = (await (db.select(
      db.rooms,
    )..where((r) => r.number.equals('102'))).getSingle()).id;
    await (db.update(
      db.rooms,
    )..where((r) => r.id.isNotIn([first, second]))).write(
      const RoomsCompanion(occupancyStatus: Value(OccupancyStatus.OCCUPIED)),
    );
    AtriumPalette.current = AtriumPalette.light;
  });
  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  Finder button(String label) =>
      find.byWidgetPredicate((w) => w is PillButton && w.label == label);
  Future<void> wait(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() => db.close().timeout(const Duration(seconds: 5)));
  }

  Future<void> open(
    WidgetTester tester, {
    bool board = true,
    Size size = const Size(1024, 800),
    double textScale = 1,
    bool readOnly = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          housekeepingRepositoryProvider.overrideWithValue(depot),
          sessionProvider.overrideWith(
            () => _TestSession(
              readOnly
                  ? SessionState(
                      agent: session.agent,
                      acces: const AccessProfile(permissions: {'rooms.read'}),
                    )
                  : session,
            ),
          ),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(
          theme: themeAtrium(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: board
              ? const RoomBoardScreen()
              : Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showRoomCleaningDialog(context),
                      child: const Text('Ouvrir'),
                    ),
                  ),
                ),
        ),
      ),
    );
    await wait(tester);
    if (!readOnly) {
      await tester.tap(
        board ? button('Ménage d’une chambre') : find.text('Ouvrir'),
      );
      await wait(tester);
    }
  }

  testWidgets(
    'depuis Chambres on sélectionne plusieurs chambres puis on les démarre',
    (tester) async {
      await open(tester);
      expect(
        tester.widget<PillButton>(button('Lancer le ménage')).onPressed,
        isNull,
      );
      expect(find.text('Chambre 103'), findsNothing);
      await tester.tap(find.byKey(ValueKey('clean-room-$first')));
      await tester.pumpAndSettle();
      expect(find.text('1 chambre sélectionnée'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('clean-room-$second')));
      await tester.pumpAndSettle();
      expect(find.text('2 chambres sélectionnées'), findsOneWidget);
      await tester.tap(button('Lancer le ménage'));
      await wait(tester);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Ménage lancé pour 2 chambres.'), findsOneWidget);
      final jobs = await tester.runAsync(() => depot.watchJobs().first);
      expect(jobs, hasLength(2));
      expect(jobs!.every((j) => j.enCours), isTrue);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'une chambre devenue occupée disparaît de la sélection avant de valider',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('Tout sélectionner'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => (db.update(db.rooms)..where((r) => r.id.equals(first))).write(
          const RoomsCompanion(
            occupancyStatus: Value(OccupancyStatus.OCCUPIED),
          ),
        ),
      );
      await wait(tester);
      expect(find.byKey(ValueKey('clean-room-$first')), findsNothing);
      expect(find.text('1 chambre sélectionnée'), findsOneWidget);
      await tester.tap(button('Lancer le ménage'));
      await wait(tester);
      final jobs = await tester.runAsync(() => depot.watchJobs().first);
      expect(jobs!.single.roomId, second);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('tout sélectionner, désélectionner et annuler ne lance rien', (
    tester,
  ) async {
    await open(tester, board: false);
    await tester.tap(find.text('Tout sélectionner'));
    await tester.pumpAndSettle();
    expect(find.text('2 chambres sélectionnées'), findsOneWidget);
    await tester.tap(find.text('Tout sélectionner'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PillButton>(button('Lancer le ménage')).onPressed,
      isNull,
    );
    await tester.tap(find.text('Annuler'));
    await wait(tester);
    expect(
      await tester.runAsync(() => db.select(db.outboxEntries).get()),
      isEmpty,
    );
    await close(tester);
  });

  testWidgets('le sélecteur tient sur téléphone avec un texte agrandi', (
    tester,
  ) async {
    await open(tester, board: false, size: const Size(375, 667), textScale: 2);
    final choice = find.byKey(ValueKey('clean-room-$first'));
    await tester.scrollUntilVisible(
      choice,
      150,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(find.text('1 chambre sélectionnée'), findsOneWidget);
    expect(
      tester.getRect(button('Lancer le ménage')).right,
      lessThanOrEqualTo(375),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Annuler'));
    await wait(tester);
    await close(tester);
  });

  testWidgets(
    'un compte sans gestion ménage ne voit pas le bouton de lancement',
    (tester) async {
      await open(tester, readOnly: true);
      expect(button('Ménage d’une chambre'), findsNothing);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );
}
