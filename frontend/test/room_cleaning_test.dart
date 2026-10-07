import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/housekeeping_repository.dart';
import 'package:atrium/data/repositories/maintenance_repository.dart';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import 'package:flutter_test/flutter_test.dart';

class _RecordingApi extends ApiClient {
  _RecordingApi()
    : super(baseUrl: 'http://localhost', tokens: const TokenStore());
  final calls = <(String, Object?)>[];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    calls.add((path, body));
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late HousekeepingRepository menage;
  late MaintenanceRepository maintenance;
  late UserRow agent;
  late List<RoomRow> rooms;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    menage = HousekeepingRepository(db);
    maintenance = MaintenanceRepository(db);
    agent = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    rooms = await (db.select(
      db.rooms,
    )..orderBy([(r) => OrderingTerm.asc(r.number)])).get();
  });
  tearDown(() => db.close());

  Future<RoomRow> room(String id) =>
      (db.select(db.rooms)..where((r) => r.id.equals(id))).getSingle();
  Future<List<OutboxEntryRow>> queued() => db.select(db.outboxEntries).get();

  test(
    'les trois comptes autorisés peuvent démarrer le ménage hors ligne',
    () async {
      for (final code in ['ADMIN01', 'RECEP01', 'MENAGE01']) {
        final user = await (db.select(
          db.users,
        )..where((u) => u.employeeCode.equals(code))).getSingle();
        expect(
          (await accessProfileFor(db, user.id)).peut('housekeeping.manage'),
          isTrue,
          reason: code,
        );
      }
      await seedAccounts(db);
      final manage = await (db.select(
        db.permissions,
      )..where((p) => p.code.equals('housekeeping.manage'))).get();
      expect(manage, hasLength(1));
    },
  );

  test(
    'la liste exclut chambres occupées, réservées, hors service et déjà en ménage',
    () async {
      final changes = [
        const RoomsCompanion(occupancyStatus: Value(OccupancyStatus.OCCUPIED)),
        const RoomsCompanion(occupancyStatus: Value(OccupancyStatus.RESERVED)),
        const RoomsCompanion(isOutOfOrder: Value(true)),
        const RoomsCompanion(
          housekeepingStatus: Value(HousekeepingStatus.IN_PROGRESS),
        ),
        const RoomsCompanion(isActive: Value(false)),
        RoomsCompanion(deletedAt: Value(DateTime.now().toUtc())),
      ];
      for (var i = 0; i < changes.length; i++) {
        await (db.update(
          db.rooms,
        )..where((r) => r.id.equals(rooms[i].id))).write(changes[i]);
      }
      final available = await menage.watchVacantRooms().first;
      expect(
        available.map((r) => r.roomId),
        unorderedEquals(rooms.skip(changes.length).map((r) => r.id)),
      );
    },
  );

  test(
    'le lancement groupé réutilise une tâche et ne démarre que les chambres choisies',
    () async {
      final pending = await menage.openTask(roomId: rooms[0].id, by: agent.id);
      final count = await menage.startVacantRooms([
        rooms[0].id,
        rooms[1].id,
        rooms[0].id,
      ], by: agent.id);
      expect(count, 2);
      expect(
        (await room(rooms[0].id)).housekeepingStatus,
        HousekeepingStatus.IN_PROGRESS,
      );
      expect(
        (await room(rooms[1].id)).housekeepingStatus,
        HousekeepingStatus.IN_PROGRESS,
      );
      expect(
        (await room(rooms[2].id)).housekeepingStatus,
        HousekeepingStatus.CLEAN,
      );
      final tasks = await db.select(db.housekeepingTasks).get();
      expect(tasks, hasLength(2));
      expect(tasks.map((t) => t.id), contains(pending));
      expect(
        tasks.every(
          (t) => t.status == TaskStatus.IN_PROGRESS && t.assignedTo == agent.id,
        ),
        isTrue,
      );
      expect(
        tasks.singleWhere((t) => t.roomId == rooms[1].id).type,
        HousekeepingTaskType.REFRESH,
      );
      final payloads = (await queued()).map(
        (e) => jsonDecode(e.payload) as Map,
      );
      expect(payloads.where((p) => p['status'] == 'IN_PROGRESS'), hasLength(2));
    },
  );

  test(
    'si une chambre est devenue occupée aucune sélection ne démarre',
    () async {
      final selected = (await menage.watchVacantRooms().first)
          .take(2)
          .map((r) => r.roomId)
          .toList();
      await (db.update(
        db.rooms,
      )..where((r) => r.id.equals(selected.last))).write(
        const RoomsCompanion(occupancyStatus: Value(OccupancyStatus.OCCUPIED)),
      );
      await expectLater(
        menage.startVacantRooms(selected, by: agent.id),
        throwsStateError,
      );
      expect(
        (await room(selected.first)).housekeepingStatus,
        HousekeepingStatus.CLEAN,
      );
      expect(await db.select(db.housekeepingTasks).get(), isEmpty);
      expect(await queued(), isEmpty);
    },
  );

  test('une sélection vide ou introuvable ne crée aucune tâche', () async {
    await expectLater(
      menage.startVacantRooms([], by: agent.id),
      throwsStateError,
    );
    await expectLater(
      menage.startVacantRooms([rooms[0].id, 'missing'], by: agent.id),
      throwsStateError,
    );
    expect(await queued(), isEmpty);
  });

  test(
    'un second ménage le même jour garde une seule carte et conserve les tâches',
    () async {
      await menage.startVacantRooms([rooms[0].id], by: agent.id);
      final previous = (await menage.watchJobs().first).single.taskId!;
      await menage.finish(previous, by: agent.id);
      await menage.startVacantRooms([rooms[0].id], by: agent.id);
      final jobs = await menage.watchJobs().first;
      expect(jobs, hasLength(1));
      expect(jobs.single.taskId, isNot(previous));
      expect(jobs.single.enCours, isTrue);
      expect(await db.select(db.housekeepingTasks).get(), hasLength(2));
    },
  );

  test(
    'les corrections de ménage effacent la fin et permettent de recommencer',
    () async {
      final id = await menage.startRoom(rooms[0].id, by: agent.id);
      await menage.finish(id, by: agent.id);
      await menage.revertRoom(
        rooms[0].id,
        to: HousekeepingStatus.IN_PROGRESS,
        by: agent.id,
      );
      var task = await (db.select(
        db.housekeepingTasks,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(task.status, TaskStatus.IN_PROGRESS);
      expect(task.finishedAt, isNull);
      expect(task.durationMinutes, isNull);
      await menage.revertRoom(
        rooms[0].id,
        to: HousekeepingStatus.DIRTY,
        by: agent.id,
      );
      task = await (db.select(
        db.housekeepingTasks,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(task.status, TaskStatus.PENDING);
      expect(task.startedAt, isNull);
      expect(task.assignedTo, isNull);
      expect(await menage.startRoom(rooms[0].id, by: agent.id), id);
    },
  );

  test(
    'rouvrir un ticket clos rebloque la chambre puis les retours enlèvent la résolution',
    () async {
      final id = await maintenance.create(
        title: 'Fuite',
        roomId: rooms[0].id,
        blocksRoom: true,
        by: agent.id,
      );
      await maintenance.take(id, by: agent.id);
      await maintenance.resolve(id, resolution: 'Joint changé', by: agent.id);
      await maintenance.close(id, by: agent.id);
      expect((await room(rooms[0].id)).isOutOfOrder, isFalse);
      await maintenance.revert(id, to: TicketStatus.RESOLVED, by: agent.id);
      expect((await room(rooms[0].id)).isOutOfOrder, isTrue);
      await maintenance.revert(id, to: TicketStatus.ASSIGNED, by: agent.id);
      var ticket = (await maintenance.watchTickets().first).single;
      expect(ticket.resolution, isNull);
      await maintenance.revert(id, to: TicketStatus.OPEN, by: agent.id);
      ticket = (await maintenance.watchTickets().first).single;
      expect(ticket.assigneeName, isNull);
      expect(ticket.status, TicketStatus.OPEN);
      await expectLater(
        maintenance.revert(id, to: TicketStatus.RESOLVED, by: agent.id),
        throwsStateError,
      );
    },
  );

  test(
    'les retours passent par les routes de correction dans le bon ordre',
    () async {
      await menage.startRoom(rooms[0].id, by: agent.id);
      await menage.revertRoom(
        rooms[0].id,
        to: HousekeepingStatus.DIRTY,
        by: agent.id,
      );
      final ticket = await maintenance.create(title: 'Ampoule', by: agent.id);
      await maintenance.take(ticket, by: agent.id);
      await maintenance.revert(ticket, to: TicketStatus.OPEN, by: agent.id);
      final api = _RecordingApi();
      final result = await OutboxSender(db: db, api: api).drain();
      expect(result.arret, DrainStop.termine);
      expect(api.calls.map((c) => c.$1.split('/').last), [
        'housekeeping-tasks',
        'start',
        'revert',
        'maintenance-tickets',
        'assign',
        'revert',
      ]);
      expect(api.calls[2].$2, {
        'from_status': 'IN_PROGRESS',
        'status': 'PENDING',
      });
      expect(api.calls.last.$2, {'from_status': 'ASSIGNED', 'status': 'OPEN'});
    },
  );
}
