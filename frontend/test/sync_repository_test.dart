/// Protection des ecritures locales en attente lors d'un rapatriement (pull).
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

RemoteRoom _room({required String occupancyStatus}) => RemoteRoom(
  id: '01920000-0000-7000-8000-00000000c001',
  number: '101',
  occupancyStatus: occupancyStatus,
  housekeepingStatus: 'CLEAN',
  isOutOfOrder: false,
  roomTypeId: '01920000-0000-7000-8000-00000000c101',
  roomTypeCode: 'STD',
  roomTypeLabel: 'Standard',
  roomTypeRate: 25000,
);

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
  });
  tearDown(() async => db.close());

  test('un pull normal met a jour une chambre non modifiee localement', () async {
    final repo = SyncRepository(db, FakeCatalogApi(rooms: [_room(occupancyStatus: 'VACANT')]));

    await repo.pullRooms();

    final chambre = await (db.select(
      db.rooms,
    )..where((r) => r.number.equals('101'))).getSingle();
    expect(chambre.occupancyStatus, OccupancyStatus.VACANT);
    expect(chambre.syncState, SyncState.synced);
  });

  test(
    'une chambre marquee pending n\'est pas ecrasee par un pull entretemps',
    () async {
      // Premier pull : la chambre arrive libre et synchronisee, comme un
      // vrai premier rafraichissement.
      final repo = SyncRepository(
        db,
        FakeCatalogApi(rooms: [_room(occupancyStatus: 'VACANT')]),
      );
      await repo.pullRooms();

      // Une modification locale survient (un check-in, simule directement
      // sur la chambre) : elle passe occupee et attend de remonter.
      await (db.update(db.rooms)..where((r) => r.number.equals('101'))).write(
        const RoomsCompanion(
          occupancyStatus: Value(OccupancyStatus.OCCUPIED),
          syncState: Value(SyncState.pending),
        ),
      );

      // Un second pull arrive entretemps, mais le serveur n'a pas encore
      // connaissance du check-in : il redit toujours VACANT.
      final repoEnRetard = SyncRepository(
        db,
        FakeCatalogApi(rooms: [_room(occupancyStatus: 'VACANT')]),
      );
      await repoEnRetard.pullRooms();

      // La modification locale doit gagner tant qu'elle n'a pas ete
      // confirmee envoyee : la chambre reste occupee.
      final chambre = await (db.select(
        db.rooms,
      )..where((r) => r.number.equals('101'))).getSingle();
      expect(chambre.occupancyStatus, OccupancyStatus.OCCUPIED);
      expect(chambre.syncState, SyncState.pending);
    },
  );
}