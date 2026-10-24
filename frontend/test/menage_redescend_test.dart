/// Le menage et la maintenance redescendent du serveur.
///
/// Vecu le 23 octobre : le menage termine sur la tablette de l'agent restait
/// « en cours » a la reception, meme apres synchronisation. Les taches
/// remontaient, mais aucune tablette ne les relisait.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/housekeeping_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

void main() {
  late AtriumDatabase db;
  late HousekeepingRepository menage;
  late String chambre;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    menage = HousekeepingRepository(db);
    chambre =
        (await db
                .customSelect('SELECT id FROM rooms ORDER BY number LIMIT 1')
                .getSingle())
            .read<String>('id');
  });
  tearDown(() => db.close());

  /// Ce que fait la file d'envoi quand le serveur a accepte : plus rien
  /// n'attend, la ligne peut etre mise a jour par la descente.
  Future<void> remontee() async {
    await db.customStatement("UPDATE outbox_entries SET status = 'ACKED'");
    await db.customStatement(
      "UPDATE housekeeping_tasks SET sync_state = 'synced'",
    );
  }

  /// Ce que la descente des chambres ecrit quand le serveur la dit propre.
  Future<void> chambreDiteParLeServeur(HousekeepingStatus statut) =>
      db.customUpdate(
        'UPDATE rooms SET housekeeping_status = ? WHERE id = ?',
        variables: [Variable.withString(statut.name), Variable(chambre)],
        updates: {db.rooms},
      );

  RemoteHousekeepingTask tache(String id, String statut) =>
      RemoteHousekeepingTask(
        id: id,
        roomId: chambre,
        type: 'DEPARTURE',
        status: statut,
        priority: 'NORMAL',
        businessDate: businessDateNow(),
      );

  Future<void> descendre({
    List<RemoteHousekeepingTask> taches = const [],
    List<RemoteMaintenanceTicket> tickets = const [],
  }) async {
    final api = FakeCatalogApi(
      housekeepingTasks: taches,
      maintenanceTickets: tickets,
    );
    final rapport = await Descente(db, api, SyncRepository(db, api)).pull();
    expect(rapport.succeeded, isTrue, reason: rapport.error);
  }

  Future<CleaningJob> travail() async =>
      (await menage.watchJobs().first).singleWhere((j) => j.roomId == chambre);

  test('le menage termine sur un autre poste se voit a la reception', () async {
    // La reception enregistre le depart : la tache nait ici, et remonte.
    final id = await menage.openTask(roomId: chambre);
    await remontee();

    // L'agent de menage l'a commencee puis terminee sur sa tablette.
    await chambreDiteParLeServeur(HousekeepingStatus.CLEAN);
    await descendre(taches: [tache(id, 'DONE')]);

    expect((await travail()).status, TaskStatus.DONE);
  });

  test('un menage commence ici et pas encore remonte fait foi', () async {
    final id = await menage.openTask(roomId: chambre);
    await remontee();
    await menage.start(id);

    // Le serveur ne sait pas encore que le menage a commence.
    await descendre(taches: [tache(id, 'PENDING')]);

    expect((await travail()).status, TaskStatus.IN_PROGRESS);
  });

  test(
    'deux postes ont chacun ouvert une tache : la chambre propre le reste',
    () async {
      // La reception ouvre la sienne ; l'agent, sans l'avoir recue, ouvre
      // et termine une autre tache sur la meme chambre.
      final restee = await menage.openTask(roomId: chambre);
      await remontee();
      await chambreDiteParLeServeur(HousekeepingStatus.CLEAN);
      await descendre(
        taches: [
          tache(restee, 'PENDING'),
          tache('01920000-0000-7000-8000-00000000a0b1', 'DONE'),
        ],
      );

      expect((await travail()).status, TaskStatus.DONE);
    },
  );

  test('un ticket de maintenance ouvert ailleurs arrive ici', () async {
    await descendre(
      tickets: [
        RemoteMaintenanceTicket(
          id: '01920000-0000-7000-8000-00000000a0c1',
          number: 'MNT-000001',
          title: 'Climatisation en panne',
          priority: 'HIGH',
          status: 'OPEN',
          roomId: chambre,
          blocksRoom: true,
        ),
      ],
    );

    final ticket = await db.select(db.maintenanceTickets).getSingle();
    expect(ticket.title, 'Climatisation en panne');
    expect(ticket.status, TicketStatus.OPEN);
    expect(ticket.blocksRoom, isTrue);
  });
}
