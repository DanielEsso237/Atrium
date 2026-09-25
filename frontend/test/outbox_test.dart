/// La file d'attente locale des ecritures a synchroniser (outbox_entries).
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

/// Depot minimal, pour tester `OutboxWriter` isolement du metier reel.
class _TestWriter with OutboxWriter {
  _TestWriter(this.db);

  @override
  final AtriumDatabase db;
}

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
  });
  tearDown(() async => db.close());

  test('une ecriture normale depose une entree dans outbox_entries', () async {
    final repo = GuestRepository(db);

    final guest = await repo.create(firstName: 'A', lastName: 'B');

    final entries = await db.select(db.outboxEntries).get();
    expect(entries, hasLength(1));

    final entry = entries.single;
    expect(entry.entityTable, 'guests');
    expect(entry.entityId, guest.id);
    expect(entry.op, SyncOp.INSERT);
  });

  test(
    'une erreur au milieu de l\'operation n\'ecrit ni la ligne ni l\'entree',
    () async {
      final writer = _TestWriter(db);
      const id = '01920000-0000-7000-8000-00000000aaaa';

      Future<void> ecritureQuiEchoue() {
        return writer.writeAndEnqueue<void>(
          table: 'guests',
          id: id,
          operation: SyncOp.INSERT,
          payload: {'id': id},
          action: () async {
            // La ligne metier s'insere d'abord...
            await db
                .into(db.guests)
                .insert(
                  GuestsCompanion.insert(
                    id: id,
                    createdAt: DateTime.now().toUtc(),
                    updatedAt: DateTime.now().toUtc(),
                    hotelId: GuestRepository.defaultHotelId,
                    code: 'CLI-TEST',
                    firstName: 'A',
                    lastName: 'B',
                  ),
                );
            // ...puis l'operation echoue avant d'atteindre `enqueue`.
            throw Exception('erreur simulee');
          },
        );
      }

      await expectLater(ecritureQuiEchoue(), throwsException);

      // Transaction annulee en bloc : ni la ligne metier, ni l'entree de la
      // file ne doivent survivre a l'erreur -- c'est le principe meme d'une
      // transaction, tout ou rien.
      expect(await db.select(db.guests).get(), isEmpty);
      expect(await db.select(db.outboxEntries).get(), isEmpty);
    },
  );
}