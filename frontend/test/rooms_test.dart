/// Organisation des chambres : categories, tarifs, plan de l'hotel.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/rooms_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
  });
  tearDown(() async => db.close());

  test('le jeu de demonstration est rejouable', () async {
    await seedDemoData(db);
    await seedDemoData(db);

    expect(await db.select(db.rooms).get(), hasLength(18));
    expect(await db.select(db.roomTypes).get(), hasLength(4));
  });

  test('chaque categorie porte son tarif et son parc', () async {
    final types = await db.roomTypeSummaries();

    // Triees par tarif croissant.
    expect(types.map((t) => t.code), ['STD', 'CLS', 'VIP', 'SUI']);
    expect(types.map((t) => t.rate), [25000, 35000, 60000, 90000]);
    expect(types.map((t) => t.roomCount), [7, 5, 4, 2]);
    expect(types.fold<int>(0, (n, t) => n + t.roomCount), 18);
  });

  test('les chambres sont bien rattachees a leur categorie', () async {
    final types = await db.roomTypeSummaries();
    final byCode = {for (final t in types) t.code: t};

    expect(byCode['VIP']!.numbers, containsAll(['203', '309']));
    expect(byCode['STD']!.numbers, containsAll(['123', '567']));

    // Une chambre appartient a une categorie et une seule.
    expect(byCode['VIP']!.numbers, isNot(contains('123')));
    expect(byCode['STD']!.numbers, isNot(contains('203')));
  });

  test('le prix vient du type, jamais de la chambre', () async {
    final board = await db.watchRoomBoard().first;
    final vip = board.where((r) => r.typeCode == 'VIP');

    // Toutes les VIP se vendent au meme tarif, quel que soit leur etage.
    expect(vip.map((r) => r.rate).toSet(), {60000});
    expect(vip.map((r) => r.number), containsAll(['203', '309']));

    // Revaloriser la categorie suffit : aucune chambre n'est touchee.
    await (db.update(db.roomTypes)..where((t) => t.code.equals('VIP'))).write(
      const RoomTypesCompanion(defaultRate: Value(75000)),
    );

    final apres = await db.watchRoomBoard().first;
    expect(apres.where((r) => r.typeCode == 'VIP').map((r) => r.rate).toSet(), {
      75000,
    });
  });

  test('la pastille du plan se calcule sur trois axes', () async {
    final board = await db.watchRoomBoard().first;
    final r203 = board.firstWhere((r) => r.number == '203');

    // Etat initial : libre et propre.
    expect(r203.displayStatus, RoomDisplayStatus.AVAILABLE);

    // Occupee ET sale : c'est l'occupation qui prime a l'affichage,
    // mais les deux informations restent stockees separement.
    await (db.update(db.rooms)..where((r) => r.number.equals('203'))).write(
      const RoomsCompanion(
        occupancyStatus: Value(OccupancyStatus.OCCUPIED),
        housekeepingStatus: Value(HousekeepingStatus.DIRTY),
      ),
    );

    var apres = await db.watchRoomBoard().first;
    var chambre = apres.firstWhere((r) => r.number == '203');
    expect(chambre.displayStatus, RoomDisplayStatus.OCCUPIED);
    expect(chambre.housekeeping, HousekeepingStatus.DIRTY);

    // Le client part : la chambre devient libre, la salete subsiste.
    await (db.update(db.rooms)..where((r) => r.number.equals('203'))).write(
      const RoomsCompanion(occupancyStatus: Value(OccupancyStatus.VACANT)),
    );

    apres = await db.watchRoomBoard().first;
    chambre = apres.firstWhere((r) => r.number == '203');
    expect(chambre.displayStatus, RoomDisplayStatus.CLEANING);

    // Une panne prime sur tout le reste.
    await (db.update(db.rooms)..where((r) => r.number.equals('203'))).write(
      const RoomsCompanion(isOutOfOrder: Value(true)),
    );

    apres = await db.watchRoomBoard().first;
    expect(
      apres.firstWhere((r) => r.number == '203').displayStatus,
      RoomDisplayStatus.MAINTENANCE,
    );
  });

  test('la disponibilite tient compte des chevauchements de dates', () async {
    final types = await db.roomTypeSummaries();
    final vip = types.firstWhere((t) => t.code == 'VIP');

    expect(
      await db.availableRoomNumbers(
        roomTypeId: vip.typeId,
        arrival: '2026-10-12',
        departure: '2026-10-15',
      ),
      hasLength(4),
    );

    // On occupe la 203 du 12 au 15.
    final r203 = (await db.watchRoomBoard().first).firstWhere(
      (r) => r.number == '203',
    );
    final now = DateTime.now().toUtc();

    await db
        .into(db.reservations)
        .insert(
          ReservationsCompanion.insert(
            id: '01920000-0000-7000-8000-000000009001',
            createdAt: now,
            updatedAt: now,
            hotelId: '01920000-0000-7000-8000-000000000001',
            reference: 'RES-0001',
            guestId: '01920000-0000-7000-8000-000000008001',
            arrivalDate: '2026-10-12',
            departureDate: '2026-10-15',
            status: const Value(ReservationStatus.CONFIRMED),
          ),
        );
    await db
        .into(db.reservationRooms)
        .insert(
          ReservationRoomsCompanion.insert(
            id: '01920000-0000-7000-8000-000000009002',
            createdAt: now,
            updatedAt: now,
            reservationId: '01920000-0000-7000-8000-000000009001',
            roomTypeId: vip.typeId,
            roomId: Value(r203.roomId),
            arrivalDate: '2026-10-12',
            departureDate: '2026-10-15',
            status: const Value(ReservationStatus.CONFIRMED),
          ),
        );

    // Sejour strictement inclus : la 203 sort.
    expect(
      await db.availableRoomNumbers(
        roomTypeId: vip.typeId,
        arrival: '2026-10-13',
        departure: '2026-10-14',
      ),
      isNot(contains('203')),
    );

    // Arrivee le jour meme du depart : aucun conflit, la chambre est reprenable.
    // C'est le piege de l'intervalle semi-ouvert -- avec `<=` elle serait
    // invendable ce jour-la.
    expect(
      await db.availableRoomNumbers(
        roomTypeId: vip.typeId,
        arrival: '2026-10-15',
        departure: '2026-10-17',
      ),
      contains('203'),
    );

    // Depart le jour de l'arrivee du sejour existant : pas de conflit non plus.
    expect(
      await db.availableRoomNumbers(
        roomTypeId: vip.typeId,
        arrival: '2026-10-10',
        departure: '2026-10-12',
      ),
      contains('203'),
    );
  });
}
