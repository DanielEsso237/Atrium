/// Les noms sur le plan des chambres : qui dort dans la chambre, ou qui y
/// est attendu aujourd'hui.
///
/// Une erreur ici ne casse rien, elle trompe : la reception enverrait un
/// client vers une chambre ou le plan affiche le nom de quelqu'un d'autre.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/queries/rooms_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late ReservationRepository reservations;

  final typeStandard = roomTypeSeeds.first.id;
  final aujourdhui = businessDayFor(DateTime.now());
  DateTime jour(int d) =>
      DateTime.utc(aujourdhui.year, aujourdhui.month, aujourdhui.day + d);

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    reservations = ReservationRepository(db);
  });

  tearDown(() => db.close());

  Future<String> chambre([int rang = 0]) async {
    final l = await db
        .customSelect(
          'SELECT id FROM rooms ORDER BY number LIMIT 1 OFFSET $rang',
        )
        .getSingle();
    return l.read<String>('id');
  }

  Future<String> sejour({
    required String roomId,
    required int arrivee,
    required int depart,
    String prenom = 'Awa',
  }) async {
    final client = await GuestRepository(
      db,
    ).create(firstName: prenom, lastName: 'Traore');
    final id = await reservations.create(
      guestId: client.id,
      roomTypeId: typeStandard,
      arrival: jour(arrivee),
      departure: jour(depart),
      nightlyRate: 25000,
      roomId: roomId,
    );
    return (await db
            .customSelect(
              'SELECT id FROM reservation_rooms WHERE reservation_id = ?',
              variables: [Variable.withString(id)],
            )
            .getSingle())
        .read<String>('id');
  }

  test('une chambre libre n a personne', () async {
    expect(await db.watchOccupantsPlan().first, isEmpty);
  });

  test(
    'le client attendu aujourd hui, puis present apres son arrivee',
    () async {
      final roomId = await chambre();
      final ligne = await sejour(roomId: roomId, arrivee: 0, depart: 2);

      final attendu = (await db.watchOccupantsPlan().first)[roomId];
      expect(attendu, isNotNull);
      expect(attendu!.nom, 'Awa Traore');
      expect(attendu.present, isFalse);
      expect(
        attendu.depart,
        DateTime(jour(2).year, jour(2).month, jour(2).day),
      );

      await reservations.checkIn(lineId: ligne);
      final present = (await db.watchOccupantsPlan().first)[roomId];
      expect(present!.present, isTrue);
    },
  );

  test('un client attendu demain n apparait pas encore', () async {
    final roomId = await chambre();
    await sejour(roomId: roomId, arrivee: 1, depart: 3);

    expect((await db.watchOccupantsPlan().first)[roomId], isNull);
  });

  test('le client present passe avant celui qu on attend', () async {
    final roomId = await chambre();
    final ligne = await sejour(roomId: roomId, arrivee: -2, depart: 0);
    await reservations.checkIn(lineId: ligne);
    // Le suivant arrive aujourd'hui dans la meme chambre, le premier n'est pas
    // encore parti.
    await sejour(roomId: roomId, arrivee: 0, depart: 2, prenom: 'Kofi');

    final occupant = (await db.watchOccupantsPlan().first)[roomId];
    expect(occupant!.nom, 'Awa Traore');
    expect(occupant.present, isTrue);
  });
}
