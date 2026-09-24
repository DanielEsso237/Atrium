/// Reservations, attribution de chambre, arrivee et depart (F1.1 a F1.3).
library;

import 'package:drift/drift.dart';

import '../../core/formats.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// Une reservation telle qu'affichee dans la liste de la reception.
class ReservationSummary {
  const ReservationSummary({
    required this.id,
    required this.lineId,
    required this.reference,
    required this.guestName,
    required this.arrival,
    required this.departure,
    required this.status,
    required this.nightlyRate,
    required this.roomTypeId,
    required this.roomTypeLabel,
    this.roomNumber,
  });

  final String id;

  /// La ligne de sejour : c'est **elle** qu'on attribue et qu'on prend en
  /// charge, pas la reservation. Une reservation de trois chambres a trois
  /// lignes, qui peuvent arriver a des moments differents.
  final String lineId;

  final String reference;
  final String guestName;
  final String arrival;
  final String departure;
  final ReservationStatus status;
  final int nightlyRate;
  final String roomTypeId;
  final String roomTypeLabel;
  final String? roomNumber;

  bool get hasRoom => roomNumber != null;
  bool get canCheckIn =>
      hasRoom &&
      (status == ReservationStatus.CONFIRMED ||
          status == ReservationStatus.PENDING);
  bool get canCheckOut => status == ReservationStatus.CHECKED_IN;
}

/// Une chambre libre, proposee a l'attribution.
class AvailableRoom {
  const AvailableRoom({required this.id, required this.number});

  final String id;
  final String number;
}

class ReservationRepository with OutboxWriter {
  ReservationRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  /// Les reservations, en flux continu, filtrees par statut si demande.
  Stream<List<ReservationSummary>> watchReservations({
    Set<ReservationStatus>? statuses,
  }) {
    return db
        .customSelect(
          '''
      SELECT r.id, r.reference,
             rr.id AS line_id, rr.arrival_date, rr.departure_date,
             rr.nightly_rate, rr.status AS line_status,
             g.first_name, g.last_name,
             rr.room_type_id,
             rt.label AS type_label,
             ch.number AS room_number
        FROM reservations r
        JOIN reservation_rooms rr ON rr.reservation_id = r.id
                                 AND rr.deleted_at IS NULL
        JOIN guests g            ON g.id = r.guest_id
        JOIN room_types rt       ON rt.id = rr.room_type_id
        LEFT JOIN rooms ch       ON ch.id = rr.room_id
       WHERE r.deleted_at IS NULL AND r.hotel_id = ?1
       ORDER BY rr.arrival_date DESC
      ''',
          variables: [Variable.withString(hotelId)],
          readsFrom: {
            db.reservations,
            db.reservationRooms,
            db.guests,
            db.roomTypes,
            db.rooms,
          },
        )
        .watch()
        .map((rows) {
          final all = rows.map(
            (l) => ReservationSummary(
              id: l.read<String>('id'),
              lineId: l.read<String>('line_id'),
              reference: l.read<String>('reference'),
              guestName:
                  '${l.read<String>('first_name')} ${l.read<String>('last_name')}',
              arrival: l.read<String>('arrival_date'),
              departure: l.read<String>('departure_date'),
              status: ReservationStatus.values.byName(
                l.read<String>('line_status'),
              ),
              nightlyRate: l.read<int>('nightly_rate'),
              roomTypeLabel: l.read<String>('type_label'),
              roomNumber: l.read<String?>('room_number'),
            ),
          );
          if (statuses == null) return all.toList();
          return all.where((v) => statuses.contains(v.status)).toList();
        });
  }

  /// Les chambres libres d'une categorie sur une periode.
  ///
  /// `availableRoomNumbers` de `rooms_queries.dart` ne renvoie que des
  /// numeros ; l'attribution a besoin de l'identifiant. Meme test de
  /// chevauchement, sur un intervalle **semi-ouvert** : un sejour du 12 au 15
  /// occupe les nuits du 12, 13 et 14 et libere la chambre le 15. Ecrire `<=`
  /// inventerait un conflit entre un depart et une arrivee le meme jour, soit
  /// une chambre invendable par jour et par rotation.
  Future<List<AvailableRoom>> availableRooms({
    required String roomTypeId,
    required DateTime arrival,
    required DateTime departure,
  }) async {
    final rows = await db
        .customSelect(
          '''
      SELECT r.id, r.number
        FROM rooms r
       WHERE r.room_type_id = ?1
         AND r.deleted_at IS NULL
         AND r.is_active = 1
         AND r.is_out_of_order = 0
         AND NOT EXISTS (
               SELECT 1 FROM reservation_rooms rr
                WHERE rr.room_id = r.id
                  AND rr.deleted_at IS NULL
                  AND rr.status IN ('PENDING','CONFIRMED','CHECKED_IN')
                  AND rr.arrival_date   < ?3
                  AND rr.departure_date > ?2
             )
       ORDER BY r.number
      ''',
          variables: [
            Variable.withString(roomTypeId),
            Variable.withString(dateIso(arrival)),
            Variable.withString(dateIso(departure)),
          ],
          readsFrom: {db.rooms, db.reservationRooms},
        )
        .get();

    return rows
        .map(
          (r) => AvailableRoom(
            id: r.read<String>('id'),
            number: r.read<String>('number'),
          ),
        )
        .toList();
  }

  /// Cree une reservation et sa ligne de sejour.
  ///
  /// Une reservation sans ligne n'aurait pas de sens : c'est la ligne qui
  /// porte le sejour — les dates, la chambre, le tarif — et c'est elle qu'on
  /// attribue puis qu'on prend en charge a l'arrivee.
  Future<String> create({
    required String guestId,
    required String roomTypeId,
    required DateTime arrival,
    required DateTime departure,
    required int nightlyRate,
    int adults = 1,
    int children = 0,
    String? roomId,
    String? notes,
    String? createdBy,
  }) async {
    final reservationId = newId();
    final lineId = newId();
    final now = DateTime.now().toUtc();
    final reference = await _nextReference();
    final nights = departure.difference(arrival).inDays;

    // Une chambre choisie des la reservation vaut attribution : le statut
    // passe a CONFIRMED, sinon la ligne reste PENDING jusqu'a l'attribution.
    final status = roomId == null
        ? ReservationStatus.PENDING
        : ReservationStatus.CONFIRMED;

    await db.transaction(() async {
      await db
          .into(db.reservations)
          .insert(
            ReservationsCompanion.insert(
              id: reservationId,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              reference: reference,
              guestId: guestId,
              status: Value(status),
              source: const Value(ReservationSource.WALK_IN),
              arrivalDate: dateIso(arrival),
              departureDate: dateIso(departure),
              adults: Value(adults),
              children: Value(children),
              estimatedTotal: Value(nightlyRate * (nights < 1 ? 1 : nights)),
              internalNotes: Value(notes),
              createdBy: Value(createdBy),
              syncState: const Value(SyncState.pending),
            ),
          );

      await db
          .into(db.reservationRooms)
          .insert(
            ReservationRoomsCompanion.insert(
              id: lineId,
              createdAt: now,
              updatedAt: now,
              reservationId: reservationId,
              roomTypeId: roomTypeId,
              roomId: Value(roomId),
              arrivalDate: dateIso(arrival),
              departureDate: dateIso(departure),
              adults: Value(adults),
              children: Value(children),
              nightlyRate: Value(nightlyRate),
              status: Value(status),
              createdBy: Value(createdBy),
              syncState: const Value(SyncState.pending),
            ),
          );

      if (roomId != null) await _markReserved(roomId, now);

      await enqueue(
        table: 'reservations',
        id: reservationId,
        operation: SyncOp.INSERT,
        payload: {
          'id': reservationId,
          'hotel_id': hotelId,
          'reference': reference,
          'guest_id': guestId,
          'status': status.name,
          'arrival_date': dateIso(arrival),
          'departure_date': dateIso(departure),
          'adults': adults,
          'children': children,
          'rooms': [
            {
              'id': lineId,
              'room_type_id': roomTypeId,
              'room_id': roomId,
              'nightly_rate': nightlyRate,
            },
          ],
        },
      );
    });

    return reservationId;
  }

  /// Attribue une chambre a une ligne de sejour (F1.3).
  Future<void> assignRoom({
    required String lineId,
    required String roomId,
    String? by,
  }) async {
    final now = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(
        db.reservationRooms,
      )..where((rr) => rr.id.equals(lineId))).write(
        ReservationRoomsCompanion(
          roomId: Value(roomId),
          status: const Value(ReservationStatus.CONFIRMED),
          updatedAt: Value(now),
          updatedBy: Value(by),
          syncState: const Value(SyncState.pending),
        ),
      );
      await _markReserved(roomId, now);
      await enqueue(
        table: 'reservation_rooms',
        id: lineId,
        operation: SyncOp.UPDATE,
        payload: {'id': lineId, 'room_id': roomId, 'status': 'CONFIRMED'},
      );
    });
  }

  /// Enregistre l'arrivee (F1.2) : la chambre devient occupee et l'ardoise
  /// s'ouvre.
  ///
  /// Le folio est cree ici et non au depart : rien ne peut se consommer sans
  /// ardoise, et le client peut commander un cafe dans la minute qui suit son
  /// arrivee.
  Future<void> checkIn({required String lineId, String? by}) async {
    final now = DateTime.now().toUtc();
    final line = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(lineId))).getSingle();

    if (line.roomId == null) {
      throw StateError(
        'Aucune chambre attribuee : impossible de prendre en charge cette '
        'arrivee.',
      );
    }

    final folioId = newId();
    final folioNumber = await _nextFolioNumber();

    await db.transaction(() async {
      await (db.update(
        db.reservationRooms,
      )..where((rr) => rr.id.equals(lineId))).write(
        ReservationRoomsCompanion(
          status: const Value(ReservationStatus.CHECKED_IN),
          checkedInAt: Value(now),
          checkedInBy: Value(by),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      await (db.update(
        db.reservations,
      )..where((r) => r.id.equals(line.reservationId))).write(
        ReservationsCompanion(
          status: const Value(ReservationStatus.CHECKED_IN),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      await (db.update(
        db.rooms,
      )..where((r) => r.id.equals(line.roomId!))).write(
        RoomsCompanion(
          occupancyStatus: const Value(OccupancyStatus.OCCUPIED),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      await db
          .into(db.folios)
          .insert(
            FoliosCompanion.insert(
              id: folioId,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              number: folioNumber,
              type: const Value(FolioType.GUEST),
              status: const Value(FolioStatus.OPEN),
              reservationRoomId: Value(lineId),
              syncState: const Value(SyncState.pending),
            ),
          );

      await enqueue(
        table: 'reservation_rooms',
        id: lineId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': lineId,
          'status': 'CHECKED_IN',
          'checked_in_at': now.toIso8601String(),
          'folio_id': folioId,
        },
      );
    });
  }

  /// Enregistre le depart : la chambre se libere et devient sale.
  ///
  /// Sale et non propre : personne n'a encore fait le menage. C'est cette
  /// ligne qui alimente la tuile « a nettoyer » du tableau de bord et la
  /// liste du housekeeping.
  Future<void> checkOut({required String lineId, String? by}) async {
    final now = DateTime.now().toUtc();
    final line = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(lineId))).getSingle();

    await db.transaction(() async {
      await (db.update(
        db.reservationRooms,
      )..where((rr) => rr.id.equals(lineId))).write(
        ReservationRoomsCompanion(
          status: const Value(ReservationStatus.CHECKED_OUT),
          checkedOutAt: Value(now),
          checkedOutBy: Value(by),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      await (db.update(
        db.reservations,
      )..where((r) => r.id.equals(line.reservationId))).write(
        ReservationsCompanion(
          status: const Value(ReservationStatus.CHECKED_OUT),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      if (line.roomId != null) {
        await (db.update(
          db.rooms,
        )..where((r) => r.id.equals(line.roomId!))).write(
          RoomsCompanion(
            occupancyStatus: const Value(OccupancyStatus.VACANT),
            housekeepingStatus: const Value(HousekeepingStatus.DIRTY),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
      }

      await enqueue(
        table: 'reservation_rooms',
        id: lineId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': lineId,
          'status': 'CHECKED_OUT',
          'checked_out_at': now.toIso8601String(),
        },
      );
    });
  }

  Future<void> _markReserved(String roomId, DateTime now) async {
    final room = await (db.select(
      db.rooms,
    )..where((r) => r.id.equals(roomId))).getSingle();
    // Une chambre deja occupee ne redevient pas « reservee » : l'occupation
    // prime, et ecraser l'axe ferait disparaitre du plan le client en place.
    if (room.occupancyStatus == OccupancyStatus.OCCUPIED) return;

    await (db.update(db.rooms)..where((r) => r.id.equals(roomId))).write(
      RoomsCompanion(
        occupancyStatus: const Value(OccupancyStatus.RESERVED),
        updatedAt: Value(now),
        syncState: const Value(SyncState.pending),
      ),
    );
  }

  Future<String> _nextReference() async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM reservations WHERE hotel_id = ?1',
          variables: [Variable.withString(hotelId)],
        )
        .getSingle();
    return 'RES-${(row.read<int>('n') + 1).toString().padLeft(6, '0')}';
  }

  Future<String> _nextFolioNumber() async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM folios WHERE hotel_id = ?1',
          variables: [Variable.withString(hotelId)],
        )
        .getSingle();
    return 'FOL-${(row.read<int>('n') + 1).toString().padLeft(6, '0')}';
  }
}
