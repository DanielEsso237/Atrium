// Ouvrir un menage n'est pas le faire (migration 0033).
//
// La reception ouvre les taches (`housekeeping.manage`) : le depart d'un
// client en cree une. Commencer, terminer et revenir en arriere sont a
// `housekeeping.work`, le geste de la femme de chambre. Le serveur refuse les
// trois a la reception ; la tablette doit les refuser avant, sinon le 403
// bloque la file d'envoi.

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
import 'package:atrium/features/alerts/alert_signal.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/housekeeping/housekeeping_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/signal_silencieux.dart';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late HousekeepingRepository menage;
  late UserRow reception;
  late UserRow femmeDeChambre;
  late String roomId;

  Future<UserRow> agent(String code) => (db.select(
    db.users,
  )..where((u) => u.employeeCode.equals(code))).getSingle();
  Future<int> enFile() async => (await db.select(db.outboxEntries).get()).length;
  Future<HousekeepingStatus> etatChambre() async => (await (db.select(
    db.rooms,
  )..where((r) => r.id.equals(roomId))).getSingle()).housekeepingStatus;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    menage = HousekeepingRepository(db);
    reception = await agent('RECEP01');
    femmeDeChambre = await agent('MENAGE01');
    roomId = (await (db.select(
      db.rooms,
    )..where((r) => r.number.equals('101'))).getSingle()).id;
  });

  group('le dépôt', () {
    tearDown(() => db.close());

    test('la réception ouvre le ménage mais ne le fait pas', () async {
      final recep = await accessProfileFor(db, reception.id);
      expect(recep.peut('housekeeping.manage'), isTrue);
      expect(recep.peut('housekeeping.work'), isFalse);
      for (final code in ['ADMIN01', 'MENAGE01']) {
        final acces = await accessProfileFor(db, (await agent(code)).id);
        expect(acces.peut('housekeeping.work'), isTrue, reason: code);
      }
    });

    test('« Commencer » par la réception n’ouvre même pas la tâche', () async {
      await expectLater(
        menage.startRoom(roomId, by: reception.id),
        throwsStateError,
      );
      expect(await db.select(db.housekeepingTasks).get(), isEmpty);
      expect(await enFile(), 0);
    });

    test(
      'la réception ne commence, ne termine ni ne corrige une tâche ouverte',
      () async {
        final taskId = await menage.openTask(roomId: roomId, by: reception.id);
        final avant = await enFile();

        await expectLater(
          menage.start(taskId, by: reception.id),
          throwsStateError,
        );
        await menage.start(taskId, by: femmeDeChambre.id);
        await expectLater(
          menage.finish(taskId, by: reception.id),
          throwsStateError,
        );
        await expectLater(
          menage.revertRoom(
            roomId,
            to: HousekeepingStatus.DIRTY,
            by: reception.id,
          ),
          throwsStateError,
        );

        // Seul le demarrage de la femme de chambre est parti dans la file.
        expect(await enFile(), avant + 1);
        expect(await etatChambre(), HousekeepingStatus.IN_PROGRESS);
      },
    );

    test('la femme de chambre fait tout le parcours', () async {
      final taskId = await menage.startRoom(roomId, by: femmeDeChambre.id);
      await menage.finish(taskId, by: femmeDeChambre.id);
      expect(await etatChambre(), HousekeepingStatus.CLEAN);
      await menage.revertRoom(
        roomId,
        to: HousekeepingStatus.IN_PROGRESS,
        by: femmeDeChambre.id,
      );
      expect(await etatChambre(), HousekeepingStatus.IN_PROGRESS);
    });
  });

  group('l’écran du ménage', () {
    // Pas de db.close ici : la fermeture attend sans fin une lecture en
    // suspens de l'ecran.

    Future<void> ouvrir(WidgetTester tester, UserRow qui) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      AtriumPalette.current = AtriumPalette.light;
      await tester.runAsync(() => menage.openTask(roomId: roomId, by: qui.id));
      final session = SessionState(
        agent: qui,
        acces: (await tester.runAsync(() => accessProfileFor(db, qui.id)))!,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(() => _TestSession(session)),
            housekeepingRepositoryProvider.overrideWithValue(menage),
            pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
            databaseProvider.overrideWithValue(db),
            signalAlerteProvider.overrideWithValue(SignalSilencieux()),
          ],
          child: MaterialApp(
            theme: themeAtrium(),
            home: const HousekeepingScreen(),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    // Demonter l'ecran puis laisser Drift solder ses minuteries : sans ca,
    // le test echoue sur des minuteries en attente, pas sur ce qu'il verifie.
    Future<void> demonter(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    PillButton commencer(WidgetTester tester) => tester.widget<PillButton>(
      find.widgetWithText(PillButton, 'Commencer'),
    );

    testWidgets('la réception voit la liste sans pouvoir commencer', (
      tester,
    ) async {
      await ouvrir(tester, reception);
      expect(find.text('101'), findsOneWidget);
      expect(commencer(tester).onPressed, isNull);
      await demonter(tester);
    });

    testWidgets('la femme de chambre peut commencer', (tester) async {
      await ouvrir(tester, femmeDeChambre);
      expect(commencer(tester).onPressed, isNotNull);
      await demonter(tester);
    });
  });
}
