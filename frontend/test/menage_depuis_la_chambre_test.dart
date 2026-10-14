/// Demander le menage depuis la fiche d'une chambre (ticket D3, 14 octobre).
///
/// La tache s'ouvre sans demarrer : c'est la femme de chambre qui la
/// commence. Une seconde demande le meme jour ne cree rien et le dit.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/housekeeping_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late HousekeepingRepository menage;
  const agent = '00000000-0000-0000-0000-0000000000a1';

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    menage = HousekeepingRepository(db);
  });

  tearDown(() => db.close());

  Future<RoomRow> chambre(String numero) => (db.select(
    db.rooms,
  )..where((r) => r.number.equals(numero))).getSingle();

  Future<List<HousekeepingTaskRow>> taches(String roomId) => (db.select(
    db.housekeepingTasks,
  )..where((t) => t.roomId.equals(roomId))).get();

  test('chambre libre : une tache REFRESH a faire, et une entree de file',
      () async {
    final c = await chambre('101');
    await db.delete(db.outboxEntries).go();

    expect(await menage.demanderMenage(c.id, by: agent), isTrue);

    final t = (await taches(c.id)).single;
    expect(t.type, HousekeepingTaskType.REFRESH);
    expect(t.status, TaskStatus.PENDING);
    expect(t.createdBy, agent);
    final file = await db.select(db.outboxEntries).get();
    expect(file, hasLength(1));
    expect(file.single.entityTable, 'housekeeping_tasks');
    final p = jsonDecode(file.single.payload) as Map<String, dynamic>;
    expect(p['type'], 'REFRESH');
    expect(p['room_id'], c.id);
  });

  test('chambre occupee : un passage STAYOVER', () async {
    final c = await chambre('101');
    await (db.update(db.rooms)..where((r) => r.id.equals(c.id))).write(
      const RoomsCompanion(occupancyStatus: Value(OccupancyStatus.OCCUPIED)),
    );
    await menage.demanderMenage(c.id, by: agent);
    expect((await taches(c.id)).single.type, HousekeepingTaskType.STAYOVER);
  });

  test('une seconde demande le meme jour ne cree rien', () async {
    final c = await chambre('101');
    expect(await menage.demanderMenage(c.id, by: agent), isTrue);
    expect(await menage.demanderMenage(c.id, by: agent), isFalse);
    expect(await taches(c.id), hasLength(1));
  });

  test('une chambre hors service est refusee', () async {
    final c = await chambre('101');
    await (db.update(db.rooms)..where((r) => r.id.equals(c.id))).write(
      const RoomsCompanion(isOutOfOrder: Value(true)),
    );
    await expectLater(
      menage.demanderMenage(c.id, by: agent),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('hors service'),
        ),
      ),
    );
    expect(await taches(c.id), isEmpty);
  });
}
