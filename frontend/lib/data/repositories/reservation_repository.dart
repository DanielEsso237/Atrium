/// Reservations, attribution de chambre, arrivee et depart (F1.1 a F1.3).
library;

import 'package:drift/drift.dart';

import '../../core/formats.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'folio_repository.dart';
import 'guest_repository.dart' show codeFromId;
import 'housekeeping_repository.dart';
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
              roomTypeId: l.read<String>('room_type_id'),
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
            Variable.withString(formatIsoDate(arrival)),
            Variable.withString(formatIsoDate(departure)),
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

  /// Les chambres ou installer un client deja arrive qui veut changer.
  ///
  /// Plus strict que l'attribution : le client est au comptoir, il entre dans
  /// la chambre dans la minute. Elle doit donc etre **propre** maintenant, pas
  /// seulement libre sur la periode -- lui tendre la cle d'une chambre sale,
  /// c'est le renvoyer au comptoir une deuxieme fois.
  ///
  /// Meme categorie que la chambre vendue : le surclassement depend d'une
  /// politique que l'hotel n'a pas encore donnee, et le serveur refuse de toute
  /// facon une chambre d'une autre categorie.
  ///
  /// La ligne elle-meme est exclue du test de chevauchement : sans ca, sa
  /// propre occupation la ferait paraitre en conflit avec toutes les chambres.
  Future<List<AvailableRoom>> roomsForChange(String lineId) async {
    final rows = await db
        .customSelect(
          '''
      SELECT r.id, r.number
        FROM reservation_rooms l
        JOIN rooms r ON r.room_type_id = l.room_type_id
       WHERE l.id = ?1
         AND r.id <> COALESCE(l.room_id, '')
         AND r.deleted_at IS NULL
         AND r.is_active = 1
         AND r.is_out_of_order = 0
         AND r.occupancy_status <> 'OCCUPIED'
         AND r.housekeeping_status IN ('CLEAN','INSPECTED')
         AND NOT EXISTS (
               SELECT 1 FROM reservation_rooms rr
                WHERE rr.room_id = r.id
                  AND rr.id <> l.id
                  AND rr.deleted_at IS NULL
                  AND rr.status IN ('PENDING','CONFIRMED','CHECKED_IN')
                  AND rr.arrival_date   < l.departure_date
                  AND rr.departure_date > l.arrival_date
             )
       ORDER BY r.number
      ''',
          variables: [Variable.withString(lineId)],
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
    final reference = codeFromId(reservationId, 'RES');
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
              arrivalDate: formatIsoDate(arrival),
              departureDate: formatIsoDate(departure),
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
              arrivalDate: formatIsoDate(arrival),
              departureDate: formatIsoDate(departure),
              adults: Value(adults),
              children: Value(children),
              nightlyRate: Value(nightlyRate),
              status: Value(status),
              createdBy: Value(createdBy),
              syncState: const Value(SyncState.pending),
            ),
          );

      if (roomId != null) await _markReserved(roomId, now);

      // CORRIGE (traçabilité, exigence 6.2) : 'created_by' est desormais
      // transmis dans le payload, a la fois pour la reservation et pour la
      // ligne de sejour. Auparavant la valeur etait bien ecrite en local
      // (createdBy: Value(createdBy) ci-dessus) mais jamais envoyee au
      // serveur : la ligne y arrivait sans agent associe.
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
          'arrival_date': formatIsoDate(arrival),
          'departure_date': formatIsoDate(departure),
          'adults': adults,
          'children': children,
          'created_by': createdBy,
          'rooms': [
            {
              'id': lineId,
              'room_type_id': roomTypeId,
              'room_id': roomId,
              'nightly_rate': nightlyRate,
              'created_by': createdBy,
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
    final previous = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(lineId))).getSingleOrNull();

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
      // Une reattribution laissait l'ancienne chambre « reservee » sur le
      // plan, pour un client qui n'y viendra plus.
      final previousRoom = previous?.roomId;
      if (previousRoom != null && previousRoom != roomId) {
        await _releaseReserved(previousRoom, lineId, now);
      }
      // CORRIGE : 'updated_by' ajoute au payload — la colonne locale
      // updatedBy etait deja remplie, seul l'envoi au serveur manquait.
      await enqueue(
        table: 'reservation_rooms',
        id: lineId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': lineId,
          'room_id': roomId,
          'status': 'CONFIRMED',
          'updated_by': by,
        },
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
    final folioNumber = codeFromId(folioId, 'FOL');

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

      // CORRIGE : 'checked_in_by' ajoute au payload — checkedInBy etait deja
      // ecrit en local (ci-dessus) mais absent de l'envoi au serveur.
      await enqueue(
        table: 'reservation_rooms',
        id: lineId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': lineId,
          'status': 'CHECKED_IN',
          'checked_in_at': now.toIso8601String(),
          'folio_id': folioId,
          'checked_in_by': by,
        },
      );
    });

    // Les nuits sont portees APRES la transaction : elles ouvrent leurs
    // propres transactions, et SQLite n'en imbrique pas. Le folio existe
    // desormais, donc elles ont ou atterrir.
    //
    // Sans cette ligne, le client repartirait en payant ses consommations et
    // zero franc de chambre.
    await FolioRepository(
      db,
      hotelId: hotelId,
    ).postStayNights(folioId: folioId, stayLineId: lineId, postedBy: by);
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

      // CORRIGE : 'checked_out_by' ajoute au payload — checkedOutBy etait
      // deja ecrit en local (ci-dessus) mais absent de l'envoi au serveur.
      await enqueue(
        table: 'reservation_rooms',
        id: lineId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': lineId,
          'status': 'CHECKED_OUT',
          'checked_out_at': now.toIso8601String(),
          'checked_out_by': by,
        },
      );
    });

    // Le menage naît du depart, mais **hors** de la transaction ci-dessus :
    // SQLite ne sait pas les imbriquer, et `openTask` a la sienne.
    //
    // Cote serveur c'est un evenement a part, pas une consequence automatique
    // du depart -- un hotel peut vouloir enregistrer une sortie sans declencher
    // de menage. Ici la reception n'a pas d'ecran pour creer une tache a la
    // main, donc c'est le depart qui l'ouvre : sans ca, la chambre serait sale
    // sur le plan et invisible pour la femme de chambre.
    if (line.roomId != null) {
      await HousekeepingRepository(db).openTask(roomId: line.roomId!, by: by);
    }
  }

  /// Installe un client deja arrive dans une autre chambre.
  ///
  /// L'ancienne redevient libre **sans** devenir sale : personne n'y a dormi.
  /// C'est toute la difference avec le depart, qui la rend a nettoyer. Son
  /// etat de menage n'est donc pas touche.
  ///
  /// L'ardoise n'a rien a faire : elle est rattachee a la ligne de sejour, pas
  /// a la chambre, et suit le client d'elle-meme.
  ///
  /// Chaque refus du serveur est verifie ici **avant** d'ecrire : un refus qui
  /// arriverait par la file la bloquerait, avec tout ce qui attend derriere.
  /// La proprete, elle, n'est verifiee que par la liste proposee
  /// (`roomsForChange`) : le serveur ne la refuse pas.
  Future<void> changeRoom({
    required String lineId,
    required String roomId,
    String? by,
  }) async {
    final now = DateTime.now().toUtc();
    final line = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(lineId))).getSingle();
    final room = await (db.select(
      db.rooms,
    )..where((r) => r.id.equals(roomId))).getSingle();

    if (line.status != ReservationStatus.CHECKED_IN) {
      throw StateError('Seul un client arrive change de chambre.');
    }
    if (line.roomId == roomId) return;
    if (room.roomTypeId != line.roomTypeId) {
      throw StateError(
        'Cette chambre n'appartient pas a la categorie reservee.',
      );
    }
    if (room.isOutOfOrder || !room.isActive) {
      throw StateError('Cette chambre est hors service.');
    }
    if (room.occupancyStatus == OccupancyStatus.OCCUPIED) {
      throw StateError('Cette chambre est deja occupee.');
    }

    await db.transaction(() async {
      await (db.update(
        db.reservationRooms,
      )..where((rr) => rr.id.equals(lineId))).write(
        ReservationRoomsCompanion(
          roomId: Value(roomId),
          updatedAt: Value(now),
          updatedBy: Value(by),
          syncState: const Value(SyncState.pending),
        ),
      );

      await (db.update(db.rooms)..where((r) => r.id.equals(roomId))).write(
        RoomsCompanion(
          occupancyStatus: const Value(OccupancyStatus.OCCUPIED),
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
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
      }

      // `action` et non `status` : le statut reste CHECKED_IN, et l'envoyeur
      // prendrait l'entree pour un second check-in.
      await enqueue(
        table: 'reservation_rooms',
        id: lineId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': lineId,
          'action': 'CHANGE_ROOM',
          'room_id': roomId,
          'updated_by': by,
        },
      );
    });
  }

  /// Rend libre la chambre qu'une ligne vient de quitter avant l'arrivee.
  ///
  /// Seulement si aucun autre sejour a venir ne la retient : elle reste
  /// « reservee » tant que quelqu'un d'autre l'attend.
  Future<void> _releaseReserved(
    String roomId,
    String leavingLineId,
    DateTime now,
  ) async {
    final room = await (db.select(
      db.rooms,
    )..where((r) => r.id.equals(roomId))).getSingleOrNull();
    if (room == null || room.occupancyStatus != OccupancyStatus.RESERVED) {
      return;
    }

    final others = await (db.select(db.reservationRooms)..where(
          (rr) =>
              rr.roomId.equals(roomId) &
              rr.id.equals(leavingLineId).not() &
              rr.deletedAt.isNull() &
              rr.status.isInValues([
                ReservationStatus.PENDING,
                ReservationStatus.CONFIRMED,
              ]),
        ))
        .get();
    if (others.isNotEmpty) return;

    await (db.update(db.rooms)..where((r) => r.id.equals(roomId))).write(
      RoomsCompanion(
        occupancyStatus: const Value(OccupancyStatus.VACANT),
        updatedAt: Value(now),
        syncState: const Value(SyncState.pending),
      ),
    );
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
}