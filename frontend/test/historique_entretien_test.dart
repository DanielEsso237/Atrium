/// Le tableau de bord et l'historique de l'entretien (18 octobre).
///
/// Ce qui compte : une tache de menage et une panne se lisent dans tous
/// leurs temps, avec qui et en combien de temps ; ce qui reste a faire ne
/// sort jamais de la liste, meme vieux ; la femme de chambre garde son seul
/// ecran.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/formats.dart';
import 'package:atrium/core/ids.dart';
import 'package:atrium/core/shell/app_shell.dart' show destinationsPour;
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/entretien_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/entretien/entretien_presentation.dart';
import 'package:atrium/features/entretien/entretien_screen.dart';
import 'package:atrium/features/entretien/historique_entretien_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atrium/features/alerts/alert_signal.dart';
import 'helpers/signal_silencieux.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late UserRow admin;
  late UserRow menage;
  late List<RoomRow> chambres;
  final aujourdhui = businessDayFor(DateTime.now());

  Future<String> tache({
    required int chambre,
    int ilYA = 0,
    TaskStatus statut = TaskStatus.DONE,
    int? duree,
    Priority priorite = Priority.NORMAL,
  }) async {
    final id = newId();
    final jour = aujourdhui.subtract(Duration(days: ilYA));
    final debut = DateTime(jour.year, jour.month, jour.day, 10).toUtc();
    final now = DateTime.now().toUtc();
    await db.into(db.housekeepingTasks).insert(
      HousekeepingTasksCompanion.insert(
        id: id, createdAt: debut, updatedAt: now, hotelId: _hotel,
        roomId: chambres[chambre].id, type: HousekeepingTaskType.DEPARTURE,
        businessDate: formatIsoDate(jour), status: Value(statut),
        priority: Value(priorite), assignedTo: Value(menage.id),
        finishedAt: Value(
          duree == null ? null : debut.add(Duration(minutes: duree)),
        ),
        durationMinutes: Value(duree),
      ),
    );
    return id;
  }

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    Future<UserRow> agent(String code) => (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals(code))).getSingle();
    admin = await agent('ADMIN01');
    menage = await agent('MENAGE01');
    chambres = await (db.select(db.rooms)
          ..orderBy([(r) => OrderingTerm(expression: r.number)]))
        .get();

    await tache(chambre: 0, duree: 30);
    await tache(chambre: 1, duree: 50, ilYA: 1);
    await tache(chambre: 2, ilYA: 20, duree: 40);
    // Une vieille tache jamais faite : elle reste dans ce qui est a faire.
    await tache(
      chambre: 3, ilYA: 20, statut: TaskStatus.PENDING,
      priorite: Priority.URGENT,
    );

    final now = DateTime.now().toUtc();
    await db.into(db.maintenanceTickets).insert(
      MaintenanceTicketsCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
        number: 'MT-1', title: 'Climatisation en panne',
        roomId: Value(chambres[4].id), priority: const Value(Priority.URGENT),
        reportedBy: Value(admin.id),
        reportedAt: Value(now.subtract(const Duration(hours: 5))),
        blocksRoom: const Value(true),
      ),
    );
    await db.into(db.maintenanceTickets).insert(
      MaintenanceTicketsCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
        number: 'MT-2', title: 'Fuite du lavabo', location: const Value('Hall'),
        status: const Value(TicketStatus.RESOLVED),
        reportedBy: Value(admin.id),
        reportedAt: Value(now.subtract(const Duration(hours: 30))),
        assignedTo: Value(admin.id),
        resolvedAt: Value(now.subtract(const Duration(hours: 6))),
        cost: const Value(15000),
      ),
    );
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  test('une tache dit sa chambre, qui l a faite et en combien de temps',
      () async {
    final semaine = await db
        .watchTachesMenage(
          depuis: formatIsoDate(aujourdhui.subtract(const Duration(days: 6))),
        )
        .first;
    // Les deux recentes, et la vieille encore a faire ; pas la vieille faite.
    expect(semaine, hasLength(3));
    final vieille = semaine.singleWhere((t) => t.aFaire);
    expect(vieille.chambre, chambres[3].number);
    final faite = semaine.firstWhere((t) => t.duree == 30);
    expect(faite.faite, isTrue);
    expect(faite.agent, '${menage.firstName} ${menage.lastName}'.trim());
    final lignes = entreesDeTache(faite);
    expect(lignes.map((e) => e.titre), contains('Chambre ${faite.chambre} faite'));
    expect(lignes.last.detail, contains('en 30 min'));

    final toutes = await db.watchTachesMenage().first;
    expect(toutes, hasLength(4));
  });

  test('une panne se lit de son signalement a sa reparation', () async {
    final pannes = await db.watchPannes().first;
    expect(pannes, hasLength(2));
    final ouverte = pannes.singleWhere((m) => m.ouverte);
    expect(ouverte.urgente, isTrue);
    expect(ouverte.ou, 'Chambre ${chambres[4].number}');
    final reglee = pannes.singleWhere((m) => !m.ouverte);
    expect(reglee.ou, 'Hall');
    final e = entreesDePanne(reglee);
    expect(e.map((x) => x.titre), contains('Panne réglée : Fuite du lavabo'));
    expect(e.firstWhere((x) => x.id.endsWith('|reglee')).montant, formatAmount(15000));
    expect(delaiMoyen([reglee]), '24 h');
  });

  test('la femme de chambre garde son seul ecran', () async {
    final menu = destinationsPour(
      SessionState(acces: await accessProfileFor(db, menage.id)),
    );
    expect(
      menu.map((d) => d.route),
      isNot(contains('/entretien/historique')),
    );
    final direction = destinationsPour(
      SessionState(acces: await accessProfileFor(db, admin.id)),
    );
    expect(
      direction.firstWhere((d) => d.route == '/entretien/historique').parent,
      '/entretien',
    );
  });

  for (final taille in [const Size(1280, 900), const Size(390, 844)]) {
    for (final (nom, ecran) in [
      ('tableau de bord', const EntretienScreen()),
      ('historique', const HistoriqueEntretienScreen()),
    ]) {
      testWidgets("le $nom de l'entretien s affiche sans debordement : $taille",
          (tester) async {
        tester.view.physicalSize = taille;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final acces =
            (await tester.runAsync(() => accessProfileFor(db, admin.id)))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              sessionProvider.overrideWith(
                () => _TestSession(SessionState(agent: admin, acces: acces)),
              ),
              pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
              signalAlerteProvider.overrideWithValue(SignalSilencieux()),
            ],
            child: MaterialApp(theme: themeAtrium(), home: ecran),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        if (taille.width > 600) {
          expect(find.textContaining('Climatisation en panne'), findsWidgets);
        }

        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.runAsync(db.close);
      });
    }
  }
}
