/// Changer de chambre un client deja arrive.
///
/// La subtilite du ticket : l'ancienne chambre redevient libre **sans**
/// devenir sale. Le depart la rend a nettoyer ; ici personne n'y a dormi, et
/// l'envoyer au menage ferait une tache pour rien.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/room_detail_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';

/// Un serveur de papier : il note les chemins qu'on lui envoie.
class _FauxApi extends ApiClient {
  _FauxApi() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final chemins = <String>[];
  final corps = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    chemins.add(path);
    corps.add((body as Map?)?.cast<String, Object?>() ?? {});
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late GuestRepository guests;
  late ReservationRepository reservations;

  final typeStandard = roomTypeSeeds.first.id;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    guests = GuestRepository(db);
    reservations = ReservationRepository(db);
  });

  tearDown(() => db.close());

  /// Les chambres de la categorie standard, par numero.
  Future<List<String>> chambresStandard() async {
    final lignes = await db
        .customSelect(
          'SELECT id FROM rooms WHERE room_type_id = ? ORDER BY number',
          variables: [Variable.withString(typeStandard)],
        )
        .get();
    return [for (final l in lignes) l.read<String>('id')];
  }

  Future<RoomRow> chambre(String id) =>
      (db.select(db.rooms)..where((r) => r.id.equals(id))).getSingle();

  Future<void> salir(String id) =>
      (db.update(db.rooms)..where((r) => r.id.equals(id))).write(
        const RoomsCompanion(
          housekeepingStatus: Value(HousekeepingStatus.DIRTY),
        ),
      );

  /// Un client arrive dans `roomId` ; renvoie sa ligne de sejour.
  Future<String> installer(String roomId) async {
    final client = await guests.create(firstName: 'Awa', lastName: 'Diallo');
    final resId = await reservations.create(
      guestId: client.id,
      roomTypeId: typeStandard,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 3),
      nightlyRate: 25000,
      roomId: roomId,
    );
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(resId))).getSingle();
    await reservations.checkIn(lineId: ligne.id);
    return ligne.id;
  }

  test('l\'ancienne chambre est disponible, pas sale', () async {
    final [ancienne, nouvelle, ...] = await chambresStandard();
    final ligne = await installer(ancienne);

    await reservations.changeRoom(lineId: ligne, roomId: nouvelle);

    final a = await chambre(ancienne);
    expect(a.occupancyStatus, OccupancyStatus.VACANT);
    expect(a.housekeepingStatus, HousekeepingStatus.CLEAN);

    // Et aucune tache de menage ouverte pour elle, contrairement au depart.
    final taches = await (db.select(
      db.housekeepingTasks,
    )..where((t) => t.roomId.equals(ancienne))).get();
    expect(taches, isEmpty);
  });

  test('la nouvelle est occupee et l\'ardoise suit le client', () async {
    final [ancienne, nouvelle, ...] = await chambresStandard();
    final ligne = await installer(ancienne);
    final folio = await (db.select(
      db.folios,
    )..where((f) => f.reservationRoomId.equals(ligne))).getSingle();

    await reservations.changeRoom(lineId: ligne, roomId: nouvelle);

    expect(
      (await chambre(nouvelle)).occupancyStatus,
      OccupancyStatus.OCCUPIED,
    );

    // La fiche de la nouvelle chambre montre le client avec son ardoise, et
    // celle de l'ancienne ne le montre plus.
    final fiche = await db.watchRoomDetail(nouvelle).first;
    expect(fiche.sejour?.lineId, ligne);
    expect(fiche.sejour?.folioId, folio.id);
    expect((await db.watchRoomDetail(ancienne).first).sejour, isNull);
  });

  test('une chambre sale n\'est pas proposee', () async {
    final [ancienne, sale, propre, ...] = await chambresStandard();
    final ligne = await installer(ancienne);
    await salir(sale);

    final proposees = await reservations.roomsForChange(ligne);
    final ids = proposees.map((r) => r.id);

    expect(ids, isNot(contains(sale)));
    expect(ids, contains(propre));
    // Ni celle ou le client est deja.
    expect(ids, isNot(contains(ancienne)));
  });

  test('une chambre d\'une autre categorie n\'est ni proposee ni acceptee',
      () async {
    final [ancienne, ...] = await chambresStandard();
    final autre = await db
        .customSelect(
          'SELECT id FROM rooms WHERE room_type_id <> ? LIMIT 1',
          variables: [Variable.withString(typeStandard)],
        )
        .getSingle();
    final autreId = autre.read<String>('id');
    final ligne = await installer(ancienne);
    final avant = await db.select(db.outboxEntries).get();

    final proposees = await reservations.roomsForChange(ligne);
    expect(proposees.map((r) => r.id), isNot(contains(autreId)));

    // Refuse avant d'ecrire : le serveur repondrait 422 et bloquerait la file.
    await expectLater(
      reservations.changeRoom(lineId: ligne, roomId: autreId),
      throwsStateError,
    );
    expect((await db.select(db.outboxEntries).get()).length, avant.length);
  });

  test('une chambre occupee est refusee avant d\'ecrire', () async {
    final [a, b, ...] = await chambresStandard();
    final ligne = await installer(a);
    await installer(b);
    final avant = await db.select(db.outboxEntries).get();

    await expectLater(
      reservations.changeRoom(lineId: ligne, roomId: b),
      throwsStateError,
    );
    expect((await db.select(db.outboxEntries).get()).length, avant.length);
  });

  test('part vers /change-room, pas comme un second check-in', () async {
    final [ancienne, nouvelle, ...] = await chambresStandard();
    final ligne = await installer(ancienne);

    await reservations.changeRoom(lineId: ligne, roomId: nouvelle);

    final entree = (await db.select(db.outboxEntries).get()).last;
    final payload = jsonDecode(entree.payload) as Map<String, dynamic>;
    expect(payload['action'], 'CHANGE_ROOM');

    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();

    expect(api.chemins.last, endsWith('/rooms/$ligne/change-room'));
    expect(api.corps.last, {'room_id': nouvelle});
    // Le check-in, parti avant, porte deja la nouvelle chambre : le serveur
    // l'installe directement la, et le changement lui repond 200.
    final checkIn = api.chemins.indexWhere((c) => c.endsWith('/check-in'));
    expect(api.corps[checkIn]['room_id'], nouvelle);
  });

  test('reattribuer avant l\'arrivee libere l\'ancienne chambre', () async {
    final [premiere, seconde, ...] = await chambresStandard();
    final client = await guests.create(firstName: 'Awa', lastName: 'Diallo');
    final resId = await reservations.create(
      guestId: client.id,
      roomTypeId: typeStandard,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 3),
      nightlyRate: 25000,
      roomId: premiere,
    );
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(resId))).getSingle();
    expect((await chambre(premiere)).occupancyStatus, OccupancyStatus.RESERVED);

    await reservations.assignRoom(lineId: ligne.id, roomId: seconde);

    expect((await chambre(premiere)).occupancyStatus, OccupancyStatus.VACANT);
    expect((await chambre(seconde)).occupancyStatus, OccupancyStatus.RESERVED);
  });
}
