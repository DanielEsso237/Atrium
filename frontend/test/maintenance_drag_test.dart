import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/maintenance_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/dashboard/dashboard_sidebar.dart';
import 'package:atrium/features/maintenance/maintenance_screen.dart';
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
  late MaintenanceRepository depot;
  late UserRow agent;
  late String ticketId;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    depot = MaintenanceRepository(db);
    agent = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    ticketId = await depot.create(title: 'Fuite du lavabo', by: agent.id);
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  Future<void> attendre(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  SessionState session({bool peutGerer = true}) => SessionState(
    agent: agent,
    acces: AccessProfile(
      permissions: {if (peutGerer) 'maintenance.manage'},
      roles: const ['Administrateur'],
    ),
  );

  Future<void> ouvrir(
    WidgetTester tester, {
    bool peutGerer = true,
    TargetPlatform platform = TargetPlatform.linux,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(
            () => _TestSession(session(peutGerer: peutGerer)),
          ),
          maintenanceRepositoryProvider.overrideWithValue(depot),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(
          theme: themeAtrium().copyWith(platform: platform),
          home: const MaintenanceScreen(),
        ),
      ),
    );
    await attendre(tester);
  }

  Future<void> deplacer(
    WidgetTester tester,
    TicketStatus vers, {
    bool appuiLong = false,
  }) async {
    final debut = tester.getCenter(find.text('Fuite du lavabo'));
    final colonne = find.byKey(ValueKey('maintenance-column-${vers.name}'));
    final fin = tester.getTopLeft(colonne) + const Offset(80, 120);
    final geste = await tester.startGesture(debut);
    if (appuiLong) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await geste.moveBy(const Offset(20, 0));
    await tester.pump();
    await geste.moveTo(fin);
    await tester.pump();
    await geste.up();
    await attendre(tester);
  }

  Future<MaintenanceTicketRow> ticket() => (db.select(
    db.maintenanceTickets,
  )..where((t) => t.id.equals(ticketId))).getSingle();

  Future<int> enFile() async => (await (db.select(
    db.outboxEntries,
  )..where((e) => e.entityTable.equals('maintenance_tickets'))).get()).length;

  testWidgets(
    'déposer dans une colonne vide prend le ticket et enfile la modification',
    (tester) async {
      await ouvrir(tester);
      await deplacer(tester, TicketStatus.ASSIGNED);
      final t = await tester.runAsync(ticket);
      expect(t!.status, TicketStatus.ASSIGNED);
      expect(t.assignedTo, agent.id);
      expect(await tester.runAsync(enFile), 2);
      expect(find.text('Marquer résolu'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'sur tablette un appui long permet de prendre le ticket par dépôt',
    (tester) async {
      await ouvrir(tester, platform: TargetPlatform.android);
      await deplacer(tester, TicketStatus.ASSIGNED, appuiLong: true);
      expect((await tester.runAsync(ticket))!.status, TicketStatus.ASSIGNED);
      expect(await tester.runAsync(enFile), 2);
      expect(tester.takeException(), isNull);
      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'la résolution par dépôt exige le compte rendu et respecte l’annulation',
    (tester) async {
      await tester.runAsync(() => depot.take(ticketId, by: agent.id));
      await ouvrir(tester);
      await deplacer(tester, TicketStatus.RESOLVED);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Annuler'));
      await attendre(tester);
      expect((await tester.runAsync(ticket))!.status, TicketStatus.ASSIGNED);
      expect(await tester.runAsync(enFile), 2);

      await deplacer(tester, TicketStatus.RESOLVED);
      final valider = find.widgetWithText(FilledButton, 'Marquer résolu');
      expect(tester.widget<FilledButton>(valider).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'Joint remplacé');
      await tester.pump();
      await tester.tap(valider);
      await attendre(tester);
      final t = await tester.runAsync(ticket);
      expect(t!.status, TicketStatus.RESOLVED);
      expect(t.resolution, 'Joint remplacé');
      expect(await tester.runAsync(enFile), 3);
      expect(tester.takeException(), isNull);
      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'un dépôt ne saute pas une étape et ne modifie pas sa propre colonne',
    (tester) async {
      await ouvrir(tester);
      await deplacer(tester, TicketStatus.RESOLVED);
      await deplacer(tester, TicketStatus.OPEN);
      expect((await tester.runAsync(ticket))!.status, TicketStatus.OPEN);
      expect(await tester.runAsync(enFile), 1);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'un ticket résolu revient en réparation puis dans Signalés par dépôt',
    (tester) async {
      await tester.runAsync(() => depot.take(ticketId, by: agent.id));
      await tester.runAsync(
        () => depot.resolve(ticketId, resolution: 'Joint changé', by: agent.id),
      );
      await ouvrir(tester);
      await deplacer(tester, TicketStatus.ASSIGNED);
      expect((await tester.runAsync(ticket))!.status, TicketStatus.ASSIGNED);
      expect((await tester.runAsync(ticket))!.resolution, isNull);
      await deplacer(tester, TicketStatus.OPEN);
      expect((await tester.runAsync(ticket))!.status, TicketStatus.OPEN);
      expect((await tester.runAsync(ticket))!.assignedTo, isNull);
      expect(await tester.runAsync(enFile), 5);
      expect(tester.takeException(), isNull);
      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'le bouton permet aussi de reprendre une réparation et de rouvrir un ticket clos',
    (tester) async {
      await tester.runAsync(() => depot.take(ticketId, by: agent.id));
      await tester.runAsync(
        () => depot.resolve(ticketId, resolution: 'Joint changé', by: agent.id),
      );
      await ouvrir(tester);
      await tester.tap(find.text('Reprendre la réparation'));
      await attendre(tester);
      expect((await tester.runAsync(ticket))!.status, TicketStatus.ASSIGNED);
      await tester.runAsync(
        () => depot.resolve(
          ticketId,
          resolution: 'Réparation vérifiée',
          by: agent.id,
        ),
      );
      await tester.runAsync(() => depot.close(ticketId, by: agent.id));
      await attendre(tester);
      await tester.tap(find.text('Clos'));
      await attendre(tester);
      await tester.tap(find.text('Rouvrir le ticket'));
      await attendre(tester);
      expect((await tester.runAsync(ticket))!.status, TicketStatus.RESOLVED);
      expect(tester.takeException(), isNull);
      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('les tickets restent en lecture seule sans le droit de gestion', (
    tester,
  ) async {
    await ouvrir(tester, peutGerer: false);
    await deplacer(tester, TicketStatus.ASSIGNED);
    expect((await tester.runAsync(ticket))!.status, TicketStatus.OPEN);
    expect(await tester.runAsync(enFile), 1);
    expect(find.text("Je m'en occupe"), findsNothing);
    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'le menu de déconnexion tient sur téléphone avec un texte agrandi',
    (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: themeAtrium(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: MenuCompte(
                  session: session(),
                  child: const Text('Compte'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Compte'));
      await tester.pumpAndSettle();
      expect(find.text('Se déconnecter'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final texte = tester.getRect(find.text('Se déconnecter'));
      expect(texte.right, lessThanOrEqualTo(375));
      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
