/// Les alertes : les bonnes situations, aux bonnes personnes, et un signal
/// qui sonne, se rappelle, puis se tait quand l'agent a vu.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/alert_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/features/alerts/alert_center.dart';
import 'package:atrium/features/alerts/alert_signal.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _moi = '01920000-0000-7000-8000-00000000a001';

class _SignalNote implements SignalAlerte {
  final emis = <NiveauAlerte>[];
  var arrets = 0;

  @override
  Future<void> emettre(NiveauAlerte niveau) async => emis.add(niveau);

  @override
  Future<void> arreter() async => arrets++;
}

class _Session extends SessionNotifier {
  _Session(this._etat);

  final SessionState _etat;

  @override
  SessionState build() => _etat;
}

void main() {
  late AtriumDatabase db;
  final t0 = DateTime.utc(2026, 10, 1);
  var n = 0;
  String id() =>
      '01920000-0000-7000-8000-${(0xb00000000000 + n++).toRadixString(16)}';
  late String chambre;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await seedDemoData(db);
    n = 0;
    chambre = (await db.select(db.rooms).get()).first.id;
  });

  tearDown(() => db.close());

  ContexteAlertes contexte(
    Set<String> droits, {
    String? accueil,
    DateTime? maintenant,
  }) => ContexteAlertes(
    agentId: _moi,
    peut: droits.contains,
    accueil: accueil,
    maintenant: maintenant ?? DateTime(2026, 10, 9, 15),
  );

  Future<void> panne(Priority priorite) => db
      .into(db.maintenanceTickets)
      .insert(
        MaintenanceTicketsCompanion.insert(
          id: id(),
          createdAt: t0,
          updatedAt: t0,
          hotelId: _hotel,
          number: 'T-$n',
          title: 'Fuite d’eau',
          roomId: Value(chambre),
          priority: Value(priorite),
          blocksRoom: const Value(true),
        ),
      );

  test('une saisie refusee bloque la file : alerte critique pour tous',
      () async {
    await db
        .into(db.outboxEntries)
        .insert(
          OutboxEntriesCompanion.insert(
            entityTable: 'payments',
            entityId: id(),
            op: SyncOp.INSERT,
            payload: '{}',
            createdAt: t0,
            status: const Value(OutboxStatus.FAILED),
            lastError: const Value('Caisse fermée'),
          ),
        );
    final alertes = await db.chargerAlertes(contexte(const {}));
    expect(alertes.single.niveau, NiveauAlerte.critique);
    expect(alertes.single.corps, startsWith('Caisse fermée.'));
  });

  test('une panne urgente sonne pour la maintenance seulement', () async {
    await panne(Priority.URGENT);
    await panne(Priority.HIGH);
    await panne(Priority.NORMAL);

    final maintenance = await db.chargerAlertes(
      contexte(const {'maintenance.read'}),
    );
    expect(maintenance.map((a) => a.niveau), [
      NiveauAlerte.critique,
      NiveauAlerte.urgente,
    ]);
    expect(maintenance.first.corps, contains('ne peut pas être louée'));
    expect(await db.chargerAlertes(contexte(const {})), isEmpty);
  });

  test('une chambre a faire alerte la femme de chambre, pas la reception',
      () async {
    await db
        .into(db.housekeepingTasks)
        .insert(
          HousekeepingTasksCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            roomId: chambre,
            type: HousekeepingTaskType.DEPARTURE,
            businessDate: '2026-10-09',
          ),
        );
    final menage = await db.chargerAlertes(
      contexte(const {'housekeeping.read'}, accueil: '/menage'),
    );
    expect(menage.single.titre, startsWith('Chambre '));
    expect(menage.single.route, '/menage');
    // Non attribuee : la reception ne la recoit pas.
    expect(
      await db.chargerAlertes(contexte(const {'housekeeping.read'})),
      isEmpty,
    );
  });

  test('un depart depasse alerte la reception, prolongation comprise',
      () async {
    final sejour = id();
    await db
        .into(db.reservationRooms)
        .insert(
          ReservationRoomsCompanion.insert(
            id: sejour,
            createdAt: t0,
            updatedAt: t0,
            reservationId: id(),
            roomTypeId: roomTypeSeeds.first.id,
            roomId: Value(chambre),
            arrivalDate: '2026-10-07',
            departureDate: '2026-10-09',
            status: const Value(ReservationStatus.CHECKED_IN),
          ),
        );
    final droits = {'reservation.read'};

    final midi = await db.chargerAlertes(
      contexte(droits, maintenant: DateTime(2026, 10, 9, 12)),
    );
    expect(midi, isEmpty, reason: 'partir a 12 h 00 est partir a l heure');

    final apres = await db.chargerAlertes(
      contexte(droits, maintenant: DateTime(2026, 10, 9, 12, 30)),
    );
    expect(apres.single.titre, startsWith('Départ dépassé'));

    // Trois heures de prolongation : plus d'alerte avant 15 h.
    final ardoise = id();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: ardoise,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            number: 'F1',
            reservationRoomId: Value(sejour),
          ),
        );
    await db
        .into(db.folioItems)
        .insert(
          FolioItemsCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            folioId: ardoise,
            category: ChargeCategory.ROOM,
            label: 'Prolongation 3 h',
            quantity: const Value(3),
            businessDate: '2026-10-09',
          ),
        );
    expect(
      await db.chargerAlertes(
        contexte(droits, maintenant: DateTime(2026, 10, 9, 14)),
      ),
      isEmpty,
    );
  });

  test('le centre sonne une fois, rappelle, et se tait quand on a vu',
      () async {
    final signal = _SignalNote();
    const rappel = Duration(milliseconds: 120);
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: _moi,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            employeeCode: 'TECH01',
            firstName: 'Ines',
            lastName: 'Test',
          ),
        );
    final agent = await (db.select(
      db.users,
    )..where((u) => u.id.equals(_moi))).getSingle();
    final conteneur = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        signalAlerteProvider.overrideWithValue(signal),
        delaisRappelProvider.overrideWithValue(
          (critique: rappel, urgente: rappel * 10),
        ),
        sessionProvider.overrideWith(
          () => _Session(
            SessionState(
              agent: agent,
              acces: const AccessProfile(permissions: {'maintenance.read'}),
            ),
          ),
        ),
      ],
    );
    addTearDown(conteneur.dispose);
    conteneur.listen(centreAlertesProvider, (_, _) {}, fireImmediately: true);
    Future<void> attendre(Duration d) => Future<void>.delayed(d);

    await attendre(const Duration(milliseconds: 50));
    expect(signal.emis, isEmpty, reason: 'rien a signaler');

    await panne(Priority.URGENT);
    await attendre(const Duration(milliseconds: 60));
    expect(signal.emis, [NiveauAlerte.critique]);
    expect(conteneur.read(centreAlertesProvider).bandeau, hasLength(1));

    await attendre(rappel * 1.5);
    expect(signal.emis.length, greaterThanOrEqualTo(2), reason: 'le rappel');

    final cle = conteneur.read(centreAlertesProvider).bandeau.single.cle;
    conteneur.read(centreAlertesProvider.notifier).acquitter(cle);
    final emis = signal.emis.length;
    expect(conteneur.read(centreAlertesProvider).bandeau, isEmpty);
    expect(signal.arrets, 1);

    await attendre(rappel * 3);
    expect(signal.emis, hasLength(emis), reason: 'vue : plus de rappel');
    // Toujours dans la cloche tant que la panne n'est pas reglee.
    expect(conteneur.read(centreAlertesProvider).actives, hasLength(1));
  });
}
