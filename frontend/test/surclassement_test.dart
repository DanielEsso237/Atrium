/// Le surclassement sur la tablette (ticket D6, 14 octobre).
///
/// Le client recoit une chambre d'une categorie superieure, a l'arrivee ou
/// en cours de sejour. Offert par defaut ; payant pour un responsable. Les
/// refus du serveur sont faits ici d'abord : sinon ils arrivent par la file
/// et la bloquent.
library;

import 'dart:convert';

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

/// Un serveur de papier : il note les chemins et les corps.
class _FauxApi extends ApiClient {
  _FauxApi() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final envois = <(String, Map<String, Object?>)>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    envois.add((path, (body as Map?)?.cast<String, Object?>() ?? {}));
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late ReservationRepository reservations;
  const agent = '00000000-0000-0000-0000-0000000000a1';
  const offert = Surclassement(motif: 'Standard en travaux');

  final typeStandard = roomTypeSeeds[0].id;
  final typeClassic = roomTypeSeeds[1].id;
  final typeVip = roomTypeSeeds[2].id;
  final aujourdhui = businessDayFor(DateTime.now());
  DateTime jour(int n) =>
      DateTime.utc(aujourdhui.year, aujourdhui.month, aujourdhui.day + n);

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    reservations = ReservationRepository(db);
  });

  tearDown(() => db.close());

  Future<RoomRow> chambre(String numero) => (db.select(
    db.rooms,
  )..where((r) => r.number.equals(numero))).getSingle();

  Future<ReservationRoomRow> ligne(String id) => (db.select(
    db.reservationRooms,
  )..where((l) => l.id.equals(id))).getSingle();

  /// Un sejour de [nuits] nuits dans [type], chambre [numero] ; rend la ligne.
  Future<String> sejour(
    String type,
    String numero, {
    int nuits = 2,
    int debut = 0,
  }) async {
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    final dossier = await reservations.create(
      guestId: client.id,
      roomTypeId: type,
      arrival: jour(debut),
      departure: jour(debut + nuits),
      nightlyRate: 25000,
      roomId: (await chambre(numero)).id,
    );
    return (await (db.select(
      db.reservationRooms,
    )..where((l) => l.reservationId.equals(dossier))).getSingle()).id;
  }

  test('la liste des surclassements : categories superieures seulement',
      () async {
    final id = await sejour(typeClassic, '201');
    final liste = await reservations.roomsForChange(id, surclassement: true);
    expect(liste, isNotEmpty);
    final types = {
      for (final c in await db.select(db.rooms).get()) c.id: c.roomTypeId,
    };
    for (final c in liste) {
      expect(types[c.id], isNot(anyOf(typeStandard, typeClassic)));
      expect(c.tarif, greaterThan(35000));
      expect(c.categorie, isNotNull);
    }
  });

  test('a l\'arrivee, offert : la categorie suit la chambre, le tarif '
      'reste, et le corps porte upgrade', () async {
    final id = await sejour(typeStandard, '101');
    final vip = await chambre('203');

    await reservations.checkIn(
      lineId: id,
      by: agent,
      roomId: vip.id,
      surclassement: offert,
    );

    final l = await ligne(id);
    expect(l.status, ReservationStatus.CHECKED_IN);
    expect(l.roomId, vip.id);
    expect(l.roomTypeId, typeVip);
    expect(l.bookedRoomTypeId, typeStandard);
    expect(l.upgradeReason, 'Standard en travaux');
    expect(l.upgradedBy, agent);
    expect(l.nightlyRate, 25000);
    expect((await chambre('203')).occupancyStatus, OccupancyStatus.OCCUPIED);

    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();
    final checkIn = api.envois.singleWhere((e) => e.$1.endsWith('/check-in'));
    expect(checkIn.$2['room_id'], vip.id);
    expect(checkIn.$2['upgrade'], {
      'keep_rate': true,
      'reason': 'Standard en travaux',
    });
  });

  test('en cours de sejour, payant : le tarif de la categorie s\'applique',
      () async {
    final id = await sejour(typeStandard, '101');
    await reservations.checkIn(lineId: id, by: agent);
    final vip = await chambre('203');
    final tarifVip = (await (db.select(
      db.roomTypes,
    )..where((t) => t.id.equals(typeVip))).getSingle()).defaultRate;

    await reservations.changeRoom(
      lineId: id,
      roomId: vip.id,
      by: agent,
      surclassement: const Surclassement(
        motif: 'Demande du client',
        garderTarif: false,
      ),
      peutChangerTarif: true,
    );

    final l = await ligne(id);
    expect(l.roomTypeId, typeVip);
    expect(l.bookedRoomTypeId, typeStandard);
    expect(l.nightlyRate, tarifVip);
    final file = await db.select(db.outboxEntries).get();
    final p = jsonDecode(file.last.payload) as Map;
    expect(p['action'], 'CHANGE_ROOM');
    expect(p['upgrade'], {'keep_rate': false, 'reason': 'Demande du client'});
  });

  test('un second surclassement garde la categorie reservee', () async {
    final id = await sejour(typeStandard, '101');
    await reservations.checkIn(
      lineId: id,
      by: agent,
      roomId: (await chambre('201')).id,
      surclassement: offert,
    );
    await reservations.changeRoom(
      lineId: id,
      roomId: (await chambre('203')).id,
      by: agent,
      surclassement: offert,
    );
    expect((await ligne(id)).bookedRoomTypeId, typeStandard);
  });

  group('les refus, avant d\'ecrire', () {
    Future<void> refuse(Future<void> geste, String morceau) => expectLater(
      geste,
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains(morceau)),
      ),
    );

    test('meme categorie, motif vide, payant sans le droit', () async {
      final id = await sejour(typeStandard, '101');
      await reservations.checkIn(lineId: id, by: agent);
      final file = (await db.select(db.outboxEntries).get()).length;

      await refuse(
        reservations.changeRoom(
          lineId: id,
          roomId: (await chambre('102')).id,
          surclassement: offert,
        ),
        'même catégorie',
      );
      await refuse(
        reservations.changeRoom(
          lineId: id,
          roomId: (await chambre('203')).id,
          surclassement: const Surclassement(motif: '   '),
        ),
        'motif',
      );
      await refuse(
        reservations.changeRoom(
          lineId: id,
          roomId: (await chambre('203')).id,
          surclassement: const Surclassement(motif: 'x', garderTarif: false),
        ),
        'responsable',
      );
      expect((await db.select(db.outboxEntries).get()).length, file);
      expect((await ligne(id)).roomTypeId, typeStandard);
    });

    test('vers une categorie inferieure : refuse', () async {
      final id = await sejour(typeVip, '203');
      await reservations.checkIn(lineId: id, by: agent);
      await refuse(
        reservations.changeRoom(
          lineId: id,
          roomId: (await chambre('201')).id,
          surclassement: offert,
        ),
        'supérieure',
      );
    });

    test('la categorie promise demain : refuse pour deux nuits, accepte '
        'pour une', () async {
      // Toutes les VIP sont reservees a partir de demain.
      final vips = await db
          .customSelect(
            'SELECT number FROM rooms WHERE room_type_id = ? '
            'AND is_active = 1 AND is_out_of_order = 0',
            variables: [Variable.withString(typeVip)],
          )
          .get();
      for (final v in vips) {
        await sejour(typeVip, v.read<String>('number'), debut: 1);
      }

      final deuxNuits = await sejour(typeStandard, '101');
      await refuse(
        reservations.checkIn(
          lineId: deuxNuits,
          by: agent,
          roomId: (await chambre('203')).id,
          surclassement: offert,
        ),
        'Plus de disponibilité',
      );
      expect((await ligne(deuxNuits)).status, isNot(ReservationStatus.CHECKED_IN));

      final uneNuit = await sejour(typeStandard, '102', nuits: 1);
      await reservations.checkIn(
        lineId: uneNuit,
        by: agent,
        roomId: (await chambre('203')).id,
        surclassement: offert,
      );
      expect((await ligne(uneNuit)).roomTypeId, typeVip);
    });
  });
}
