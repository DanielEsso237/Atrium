/// Reservations, attribution de chambre, arrivee et depart (F1.1 a F1.3).
library;

import 'package:drift/drift.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/ids.dart';
import '../../core/prolongation.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'cash_repository.dart';
import 'folio_repository.dart';
import 'guest_repository.dart' show codeFromId;
import 'housekeeping_repository.dart';
import 'outbox.dart';
import 'room_order_repository.dart';
import 'settings_repository.dart';

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
    this.depositAmount,
    this.depositPaid = false,
    this.guestId = '',
  });

  final String id;

  /// Le client du dossier : sa fiche s'ouvre depuis la ligne.
  final String guestId;

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

  /// Les arrhes du dossier, `null` ou zero s'il n'y en a pas.
  final int? depositAmount;

  /// Encaissees ; sinon dues, a demander au client.
  final bool depositPaid;

  bool get hasDeposit => (depositAmount ?? 0) > 0;

  /// Annulable tant que le client n'est pas arrive : ensuite, il part par le
  /// check-out, et le serveur refuserait l'annulation.
  bool get canCancel =>
      status == ReservationStatus.PENDING ||
      status == ReservationStatus.CONFIRMED;

  bool get hasRoom => roomNumber != null;
  bool get canCheckIn =>
      hasRoom &&
      (status == ReservationStatus.CONFIRMED ||
          status == ReservationStatus.PENDING);
  bool get canCheckOut => status == ReservationStatus.CHECKED_IN;
}

/// Une chambre libre, proposee a l'attribution.
class AvailableRoom {
  const AvailableRoom({
    required this.id,
    required this.number,
    this.categorie,
    this.tarif,
  });

  final String id;
  final String number;

  /// La categorie et son tarif par nuit, pour une chambre de surclassement.
  final String? categorie;
  final int? tarif;
}

/// Un surclassement (demande du 14 octobre) : le client dort dans une
/// categorie superieure a celle qu'il a reservee.
class Surclassement {
  const Surclassement({required this.motif, this.garderTarif = true});

  /// Pourquoi : « Standard en travaux », « client fidele ».
  final String motif;

  /// Offert par defaut : le tarif reserve reste. Faux, le tarif de la
  /// nouvelle categorie s'applique aux nuits pas encore portees, et il faut
  /// `reservation.manage`.
  final bool garderTarif;

  Map<String, Object?> get payload => {
    'keep_rate': garderTarif,
    'reason': motif.trim(),
  };
}

/// Une chambre ou installer un voyageur sans reservation.
class ChambreLibre {
  const ChambreLibre({
    required this.id,
    required this.numero,
    required this.categorieId,
    required this.categorie,
    required this.tarif,
    required this.propre,
  });

  final String id;
  final String numero;
  final String categorieId;
  final String categorie;

  /// Le tarif de la nuit de sa categorie : le prix propose en nuits.
  final int tarif;
  final bool propre;
}

/// Comment se compte un sejour d'arrivee directe. Les noms sont ceux du
/// contrat (`unit` de `POST /stays/walk-in`).
// ignore: constant_identifier_names
enum UniteSejour { NIGHTS, HOURS }

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
      SELECT r.id, r.reference, r.guest_id,
             r.deposit_amount,
             (r.deposit_paid_at IS NOT NULL) AS deposit_paid,
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
              guestId: l.read<String>('guest_id'),
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
              depositAmount: l.read<int?>('deposit_amount'),
              depositPaid: l.read<int>('deposit_paid') == 1,
            ),
          );
          if (statuses == null) return all.toList();
          return all.where((v) => statuses.contains(v.status)).toList();
        });
  }

  /// Le jour de depart prevu d'une ligne de sejour (date seule).
  Future<DateTime?> departureDayOfLine(String lineId) async {
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(lineId))).getSingleOrNull();
    return ligne == null ? null : parseIsoDate(ligne.departureDate);
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
         -- Un client prolonge n'a pas encore rendu la chambre : le jour de
         -- son depart elle reste occupee, au-dela de l'heure de depart.
         AND NOT EXISTS (
               SELECT 1
                 FROM reservation_rooms rr
                 JOIN folios f      ON f.reservation_room_id = rr.id
                                   AND f.deleted_at IS NULL
                 JOIN folio_items i ON i.folio_id = f.id
                                   AND i.deleted_at IS NULL
                                   AND i.is_void = 0
                                   AND i.category = 'ROOM'
                                   AND i.label LIKE ?4
                WHERE rr.room_id = r.id
                  AND rr.deleted_at IS NULL
                  AND rr.status = 'CHECKED_IN'
                  AND rr.departure_date = ?2
             )
       ORDER BY r.number
      ''',
          variables: [
            Variable.withString(roomTypeId),
            Variable.withString(formatIsoDate(arrival)),
            Variable.withString(formatIsoDate(departure)),
            Variable.withString('$libelleProlongation%'),
          ],
          readsFrom: {
            db.rooms,
            db.reservationRooms,
            db.folios,
            db.folioItems,
          },
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
  ///
  /// Avec `surclassement`, les chambres des categories **superieures** --
  /// un tarif par nuit plus eleve que celui de la categorie du client --,
  /// les moins cheres d'abord (decision du 14 octobre : on ne surclasse que
  /// vers le haut).
  Future<List<AvailableRoom>> roomsForChange(
    String lineId, {
    bool surclassement = false,
  }) async {
    final categorie = surclassement
        ? '''r.room_type_id IN (
               SELECT t.id FROM room_types t
                WHERE t.deleted_at IS NULL
                  AND t.default_rate > (SELECT default_rate FROM room_types
                                         WHERE id = l.room_type_id))'''
        : 'r.room_type_id = l.room_type_id';
    final rows = await db
        .customSelect(
          '''
      SELECT r.id, r.number, t.label AS categorie, t.default_rate AS tarif
        FROM reservation_rooms l
        JOIN rooms r ON $categorie
        JOIN room_types t ON t.id = r.room_type_id
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
       ORDER BY t.default_rate, r.number
      ''',
          variables: [Variable.withString(lineId)],
          readsFrom: {db.rooms, db.reservationRooms, db.roomTypes},
        )
        .get();

    return rows
        .map(
          (r) => AvailableRoom(
            id: r.read<String>('id'),
            number: r.read<String>('number'),
            categorie: surclassement ? r.read<String>('categorie') : null,
            tarif: surclassement ? r.read<int>('tarif') : null,
          ),
        )
        .toList();
  }

  /// Verifie qu'un surclassement passera, sans rien ecrire.
  ///
  /// Les refus de `check-in` et `change-room` avec `upgrade`, recopies avant
  /// la file : un refus par la file la bloquerait. Categorie identique, motif
  /// vide, tarif payant sans le droit, categorie inferieure (decision du 14
  /// octobre), et la nouvelle categorie complete une des nuits qui restent
  /// -- de la journee hoteliere en cours au depart. Un sejour en heures
  /// n'occupe aucune nuit : jamais bloque.
  Future<void> verifierSurclassement({
    required String lineId,
    required String roomId,
    required Surclassement surclassement,
    required bool peutChangerTarif,
  }) async {
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((l) => l.id.equals(lineId))).getSingle();
    final chambre = await (db.select(
      db.rooms,
    )..where((r) => r.id.equals(roomId))).getSingle();
    if (chambre.roomTypeId == ligne.roomTypeId) {
      throw StateError(
        'La chambre ${chambre.number} est de la même catégorie : ce n’est '
        'pas un surclassement.',
      );
    }
    final motif = surclassement.motif.trim();
    if (motif.isEmpty) throw StateError('Indiquez le motif du surclassement.');
    if (motif.length > 255) {
      throw StateError('Le motif fait 255 caractères au plus.');
    }
    if (!surclassement.garderTarif && !peutChangerTarif) {
      throw StateError(
        'Seul un responsable peut faire payer un surclassement : il change '
        'le prix du séjour.',
      );
    }
    final actuelle = await (db.select(
      db.roomTypes,
    )..where((t) => t.id.equals(ligne.roomTypeId))).getSingle();
    final nouvelle = await (db.select(
      db.roomTypes,
    )..where((t) => t.id.equals(chambre.roomTypeId))).getSingle();
    if (nouvelle.defaultRate <= actuelle.defaultRate) {
      throw StateError(
        'On ne surclasse que vers une catégorie supérieure : '
        '${nouvelle.label} n’est pas au-dessus de ${actuelle.label}.',
      );
    }
    if (ligne.stayUnit == UniteSejour.HOURS.name) return;

    final aujourdhui = businessDayFor(DateTime.now());
    final arrivee = parseIsoDate(ligne.arrivalDate)!;
    final depart = parseIsoDate(ligne.departureDate)!;
    final total = await db
        .customSelect(
          '''
      SELECT COUNT(*) AS n FROM rooms
       WHERE room_type_id = ?1 AND deleted_at IS NULL
         AND is_active = 1 AND is_out_of_order = 0
      ''',
          variables: [Variable.withString(nouvelle.id)],
          readsFrom: {db.rooms},
        )
        .getSingle();
    final chambres = total.read<int>('n');
    for (
      var nuit = arrivee.isAfter(aujourdhui) ? arrivee : aujourdhui;
      nuit.isBefore(depart);
      nuit = DateTime(nuit.year, nuit.month, nuit.day + 1)
    ) {
      final jour = formatIsoDate(nuit);
      final prises = await db
          .customSelect(
            '''
        SELECT COUNT(*) AS n FROM reservation_rooms
         WHERE room_type_id = ?1 AND id <> ?3 AND deleted_at IS NULL
           AND status IN ('PENDING','CONFIRMED','CHECKED_IN')
           AND COALESCE(stay_unit, 'NIGHTS') <> 'HOURS'
           AND arrival_date <= ?2 AND departure_date > ?2
        ''',
            variables: [
              Variable.withString(nouvelle.id),
              Variable.withString(jour),
              Variable.withString(lineId),
            ],
            readsFrom: {db.reservationRooms},
          )
          .getSingle();
      if (prises.read<int>('n') >= chambres) {
        throw StateError(
          'Plus de disponibilité pour « ${nouvelle.label} » la nuit du '
          '${formatShortDate(nuit)} : elle est promise à une réservation.',
        );
      }
    }
  }

  /// Ce qu'un surclassement ecrit sur la ligne : la categorie de la
  /// chambre, la categorie reservee gardee (meme apres un second
  /// surclassement), le motif, et le tarif si le surclassement est payant.
  Future<ReservationRoomsCompanion> _ecritureSurclassement(
    ReservationRoomRow ligne,
    RoomRow chambre,
    Surclassement s,
    String? by,
  ) async {
    final nouvelle = await (db.select(
      db.roomTypes,
    )..where((t) => t.id.equals(chambre.roomTypeId))).getSingle();
    return ReservationRoomsCompanion(
      roomTypeId: Value(chambre.roomTypeId),
      bookedRoomTypeId: Value(ligne.bookedRoomTypeId ?? ligne.roomTypeId),
      upgradeReason: Value(s.motif.trim()),
      upgradedBy: Value(by),
      nightlyRate: s.garderTarif
          ? const Value.absent()
          : Value(nouvelle.defaultRate),
    );
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
    int? depositCollected,
    PaymentMethod? depositMethod,
  }) async {
    final reservationId = newId();
    final lineId = newId();
    final now = DateTime.now().toUtc();
    final reference = codeFromId(reservationId, 'RES');
    final nights = departure.difference(arrival).inDays;
    final total = nightlyRate * (nights < 1 ? 1 : nights);

    // Les arrhes. Encaissees : le montant saisi, refuse ici dans les deux
    // cas ou le serveur le refuserait (422), sinon la file se bloquerait.
    // Seulement dues : la regle de l'hotel, calculee comme le serveur.
    final collectees = depositCollected != null && depositCollected > 0;
    if (collectees) {
      if (depositCollected > total) {
        throw StateError(
          'Les arrhes (${formatAmount(depositCollected)}) dépassent le prix '
          'du séjour (${formatAmount(total)}).',
        );
      }
      if (depositMethod == null) {
        throw StateError('Choisissez comment les arrhes sont payées.');
      }
    }
    final arrhes = collectees
        ? depositCollected
        : (await SettingsRepository(db).depositRule())?.depositFor(total) ?? 0;

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
              estimatedTotal: Value(total),
              depositAmount: Value(arrhes),
              depositPaidAt: Value(collectees ? now : null),
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

      // Les arrhes encaissees : un vrai paiement, dans la caisse ouverte de
      // celui qui encaisse, comme cote serveur -- sinon l'attendu du tiroir
      // ne les compterait pas. Pas encore d'ardoise : elles y passeront a
      // l'arrivee. Pas enfile : le serveur cree son propre paiement a partir
      // de la reservation ci-dessous.
      if (collectees) {
        await db
            .into(db.payments)
            .insert(
              PaymentsCompanion.insert(
                id: newId(),
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                method: depositMethod!,
                amount: depositCollected,
                receivedBy: Value(createdBy),
                cashSessionId: Value(
                  createdBy == null
                      ? null
                      : await CashRepository(db).openSessionId(createdBy),
                ),
                receivedAt: Value(now),
                businessDate: Value(formatIsoDate(businessDayFor(now))),
                notes: Value(depositNote(reference)),
                syncState: const Value(SyncState.synced),
              ),
            );
      }

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
          // Absentes : le serveur applique la regle de l'hotel, rien
          // d'encaisse. Presentes : des arrhes reellement recues.
          'deposit_amount': collectees ? depositCollected : null,
          'deposit_method': collectees ? depositMethod!.name : null,
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

  /// Les nuits que couvre une arrivee directe faite maintenant : de la
  /// journee hoteliere en cours a son depart. En heures, la nuit de ce soir :
  /// le client part avant, mais une chambre promise a l'arrivee de ce soir
  /// ne se donne pas pour quelques heures.
  static (DateTime, DateTime) nuitsDuSejour(UniteSejour unite, int duree) {
    final arrivee = businessDayFor(DateTime.now());
    final nuits = unite == UniteSejour.NIGHTS ? duree : 1;
    return (
      arrivee,
      DateTime(arrivee.year, arrivee.month, arrivee.day + nuits),
    );
  }

  /// Les chambres ou installer un voyageur tout de suite, pour la duree
  /// choisie : en service, pas occupees, et ni attribuees a une reservation
  /// sur ces nuits, ni dans une categorie que les reservations sans chambre
  /// remplissent deja. C'est ce que `verifierArriveeDirecte` laisse passer :
  /// la liste ne propose plus une chambre que l'enregistrement refuse
  /// (reunion du 18 octobre). L'etat du menage est dit, pas impose : la
  /// reception sait si la chambre peut se donner.
  Stream<List<ChambreLibre>> watchChambresLibres({
    UniteSejour unite = UniteSejour.NIGHTS,
    int duree = 1,
  }) {
    final (arrivee, depart) = nuitsDuSejour(unite, duree);
    return db
        .customSelect(
          '''
      SELECT r.id, r.number, r.housekeeping_status AS menage,
             t.id AS categorie_id, t.label AS categorie,
             t.default_rate AS tarif
        FROM rooms r
        JOIN room_types t ON t.id = r.room_type_id
       WHERE r.deleted_at IS NULL
         AND r.is_active = 1
         AND r.is_out_of_order = 0
         AND r.occupancy_status <> 'OCCUPIED'
         AND NOT EXISTS (
               SELECT 1 FROM reservation_rooms rr
                WHERE rr.room_id = r.id AND rr.status = 'CHECKED_IN'
                  AND rr.deleted_at IS NULL)
         AND NOT EXISTS (
               SELECT 1 FROM reservation_rooms rr
                WHERE rr.room_id = r.id
                  AND rr.deleted_at IS NULL
                  AND rr.status IN ('PENDING','CONFIRMED')
                  AND rr.arrival_date   < ?2
                  AND rr.departure_date > ?1)
       ORDER BY r.number
      ''',
          variables: [
            Variable.withString(formatIsoDate(arrivee)),
            Variable.withString(formatIsoDate(depart)),
          ],
          readsFrom: {db.rooms, db.roomTypes, db.reservationRooms},
        )
        .watch()
        .asyncMap((rows) async {
          // Une categorie pleine sur l'une des nuits ne propose rien : ses
          // chambres libres sont promises a des reservations sans chambre.
          final pleines = <String>{};
          if (unite == UniteSejour.NIGHTS) {
            for (final id in {
              for (final r in rows) r.read<String>('categorie_id'),
            }) {
              if (await _nuitComplete(id, arrivee, duree) != null) {
                pleines.add(id);
              }
            }
          }
          return [
            for (final r in rows)
              if (!pleines.contains(r.read<String>('categorie_id')))
                ChambreLibre(
                  id: r.read<String>('id'),
                  numero: r.read<String>('number'),
                  categorieId: r.read<String>('categorie_id'),
                  categorie: r.read<String>('categorie'),
                  tarif: r.read<int>('tarif'),
                  propre: const ['CLEAN', 'INSPECTED'].contains(
                    r.read<String>('menage'),
                  ),
                ),
          ];
        });
  }

  /// La premiere nuit ou la categorie n'a plus de chambre a donner, ou nul.
  /// Une reservation sans chambre attribuee prend quand meme une place : la
  /// meme regle que `_ensure_available` cote serveur.
  Future<String?> _nuitComplete(
    String roomTypeId,
    DateTime arrivee,
    int nuits,
  ) async {
    final total = await db
        .customSelect(
          '''
      SELECT COUNT(*) AS n FROM rooms
       WHERE room_type_id = ?1 AND deleted_at IS NULL
         AND is_active = 1 AND is_out_of_order = 0
      ''',
          variables: [Variable.withString(roomTypeId)],
          readsFrom: {db.rooms},
        )
        .getSingle();
    final chambres = total.read<int>('n');
    for (var i = 0; i < nuits; i++) {
      final nuit = formatIsoDate(
        DateTime(arrivee.year, arrivee.month, arrivee.day + i),
      );
      final prises = await db
          .customSelect(
            '''
        SELECT COUNT(*) AS n FROM reservation_rooms
         WHERE room_type_id = ?1 AND deleted_at IS NULL
           AND status IN ('PENDING','CONFIRMED','CHECKED_IN')
           AND COALESCE(stay_unit, 'NIGHTS') <> 'HOURS'
           AND arrival_date <= ?2 AND departure_date > ?2
        ''',
            variables: [
              Variable.withString(roomTypeId),
              Variable.withString(nuit),
            ],
            readsFrom: {db.reservationRooms},
          )
          .getSingle();
      if (prises.read<int>('n') >= chambres) return nuit;
    }
    return null;
  }

  /// Verifie qu'une arrivee directe passera, sans rien ecrire.
  ///
  /// Ce que le serveur refuserait (`POST /stays/walk-in`) est refuse ici
  /// d'abord : un refus par la file la bloquerait, l'arrivee du client avec.
  /// L'ecran l'appelle avant de creer la fiche d'un nouveau client, pour ne
  /// pas laisser une fiche orpheline derriere un refus.
  Future<void> verifierArriveeDirecte({
    required String roomId,
    required UniteSejour unite,
    required int duree,
    required int prix,
    String? guestId,
  }) async {
    if (unite == UniteSejour.NIGHTS && (duree < 1 || duree > 365)) {
      throw StateError('Indiquez entre 1 et 365 nuits.');
    }
    if (unite == UniteSejour.HOURS && (duree < 1 || duree > 24)) {
      throw StateError('Indiquez entre 1 et 24 heures.');
    }
    if (prix < 0) throw StateError('Le prix ne peut pas être négatif.');

    final chambre = await (db.select(
      db.rooms,
    )..where((r) => r.id.equals(roomId))).getSingleOrNull();
    if (chambre == null || chambre.deletedAt != null || !chambre.isActive) {
      throw StateError('Chambre introuvable.');
    }
    if (chambre.isOutOfOrder) {
      throw StateError('La chambre ${chambre.number} est hors service.');
    }
    final occupee = await db
        .customSelect(
          '''
      SELECT 1 FROM reservation_rooms
       WHERE room_id = ?1 AND status = 'CHECKED_IN' AND deleted_at IS NULL
       LIMIT 1
      ''',
          variables: [Variable.withString(roomId)],
          readsFrom: {db.reservationRooms},
        )
        .getSingleOrNull();
    if (occupee != null ||
        chambre.occupancyStatus == OccupancyStatus.OCCUPIED) {
      throw StateError('La chambre ${chambre.number} est occupée.');
    }

    // La chambre ne doit pas etre promise a une reservation sur les nuits du
    // sejour. En heures, la nuit de ce soir compte aussi : le client part
    // avant, mais la chambre attendue ce soir ne se donne pas entre-temps.
    final (arrivee, depart) = nuitsDuSejour(unite, duree);
    final libres = await availableRooms(
      roomTypeId: chambre.roomTypeId,
      arrival: arrivee,
      departure: depart,
    );
    if (!libres.any((r) => r.id == roomId)) {
      throw StateError(
        unite == UniteSejour.NIGHTS
            ? 'La chambre ${chambre.number} est promise à une réservation sur '
                  'ces nuits : choisissez-en une autre.'
            : 'La chambre ${chambre.number} est promise à une réservation ce '
                  'soir : choisissez-en une autre.',
      );
    }
    // En nuits, la categorie doit avoir une chambre libre chaque nuit. En
    // heures, le client sera parti avant le soir.
    if (unite == UniteSejour.NIGHTS) {
      final nuit = await _nuitComplete(chambre.roomTypeId, arrivee, duree);
      if (nuit != null) {
        throw StateError(
          'Plus de chambre libre dans cette catégorie la nuit du '
          '${formatShortDate(parseIsoDate(nuit)!)} : elles sont toutes '
          'réservées.',
        );
      }
    }

    // Le plafond d'un client connu : tout ce qu'il doit deja, plus ce sejour.
    if (guestId != null) {
      final r = await db
          .customSelect(
            '''
        SELECT COALESCE(g.credit_limit, 0) AS seuil,
               COALESCE((SELECT SUM(f.balance) FROM folios f
                          WHERE f.guest_id = g.id AND f.status = 'OPEN'
                            AND f.deleted_at IS NULL), 0) AS du
          FROM guests g WHERE g.id = ?1
        ''',
            variables: [Variable.withString(guestId)],
            readsFrom: {db.guests, db.folios},
          )
          .getSingleOrNull();
      if (r == null) throw StateError('Client introuvable.');
      final seuil = r.read<int>('seuil');
      final du = r.read<int>('du');
      if (seuil > 0 && du + prix > seuil) {
        throw StateError(
          'Seuil dépassé : ce client doit déjà ${formatAmount(du)}, plus '
          '${formatAmount(prix)} de séjour, pour un plafond de '
          '${formatAmount(seuil)}. Un responsable doit autoriser.',
        );
      }
    }
  }

  /// L'arrivee directe (demande du 14 octobre) : un voyageur sans
  /// reservation prend une chambre, pour des nuits ou quelques heures, a un
  /// prix convenu -- le prix du sejour entier.
  ///
  /// En un geste, comme le serveur (`POST /stays/walk-in`) : le dossier, la
  /// ligne arrivee, la chambre occupee, l'ardoise et une seule charge
  /// « Sejour 3 h » ou « Sejour 2 nuits ». Ses nuits ne se portent pas une a
  /// une : la charge les couvre. Une seule entree de file remonte le tout,
  /// avec les identifiants choisis ici. Rend l'identifiant de la ligne.
  Future<String> arriveeDirecte({
    required String guestId,
    required String roomId,
    required UniteSejour unite,
    required int duree,
    required int prix,
    required String by,
  }) async {
    await verifierArriveeDirecte(
      roomId: roomId,
      unite: unite,
      duree: duree,
      prix: prix,
      guestId: guestId,
    );
    final chambre = await (db.select(
      db.rooms,
    )..where((r) => r.id.equals(roomId))).getSingle();
    final categorie = await (db.select(
      db.roomTypes,
    )..where((t) => t.id.equals(chambre.roomTypeId))).getSingleOrNull();

    final reservationId = newId();
    final lineId = newId();
    final folioId = newId();
    final chargeId = newId();
    final now = DateTime.now().toUtc();
    final arrivee = businessDayFor(now);
    final enHeures = unite == UniteSejour.HOURS;
    // En heures, la date de depart vaut le lendemain parce que le schema
    // exige depart > arrivee ; c'est `departureAt` qui fait foi.
    final depart = DateTime(
      arrivee.year,
      arrivee.month,
      arrivee.day + (enHeures ? 1 : duree),
    );
    final departA = enHeures ? now.add(Duration(hours: duree)) : null;
    final parNuit = enHeures ? 0 : prix ~/ duree;
    // Qui a fixe le prix, quand il n'est pas le tarif : toujours en heures,
    // qui n'ont pas de tarif.
    final tarif = (categorie?.defaultRate ?? 0) * duree;
    final prixFixe = enHeures || prix != tarif;
    final libelle = enHeures
        ? 'Séjour $duree h'
        : 'Séjour $duree nuit${duree > 1 ? 's' : ''}';
    final reference = codeFromId(reservationId, 'RES');

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
              status: const Value(ReservationStatus.CHECKED_IN),
              source: const Value(ReservationSource.WALK_IN),
              arrivalDate: formatIsoDate(arrivee),
              departureDate: formatIsoDate(depart),
              estimatedTotal: Value(prix),
              createdBy: Value(by),
              // Protege jusqu'a la remontee : c'est l'entree de la file.
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
              roomTypeId: chambre.roomTypeId,
              roomId: Value(roomId),
              arrivalDate: formatIsoDate(arrivee),
              departureDate: formatIsoDate(depart),
              nightlyRate: Value(parNuit),
              status: const Value(ReservationStatus.CHECKED_IN),
              checkedInAt: Value(now),
              checkedInBy: Value(by),
              isWalkIn: const Value(true),
              stayUnit: Value(unite.name),
              departureAt: Value(departA),
              rateSetBy: Value(prixFixe ? by : null),
              createdBy: Value(by),
              // Remonte avec le dossier, pas a part.
              syncState: const Value(SyncState.synced),
            ),
          );
      await (db.update(db.rooms)..where((r) => r.id.equals(roomId))).write(
        RoomsCompanion(
          occupancyStatus: const Value(OccupancyStatus.OCCUPIED),
          updatedAt: Value(now),
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
              number: codeFromId(folioId, 'FOL'),
              type: const Value(FolioType.GUEST),
              status: const Value(FolioStatus.OPEN),
              reservationRoomId: Value(lineId),
              guestId: Value(guestId),
              openedAt: Value(now),
              syncState: const Value(SyncState.synced),
            ),
          );
      await db
          .into(db.folioItems)
          .insert(
            FolioItemsCompanion.insert(
              id: chargeId,
              createdAt: now,
              updatedAt: now,
              folioId: folioId,
              category: ChargeCategory.ROOM,
              label: libelle,
              unitPrice: Value(prix),
              amount: Value(prix),
              businessDate: formatIsoDate(arrivee),
              postedBy: Value(by),
              postedAt: Value(now),
              syncState: const Value(SyncState.synced),
            ),
          );
      await FolioRepository(db, hotelId: hotelId).recalculer(folioId);
      await enqueue(
        table: 'reservations',
        id: reservationId,
        operation: SyncOp.INSERT,
        payload: {
          'id': reservationId,
          'action': 'WALK_IN',
          'line_id': lineId,
          'folio_id': folioId,
          'charge_id': chargeId,
          'guest_id': guestId,
          'room_id': roomId,
          'unit': unite.name,
          'duration': duree,
          'price': prix,
        },
      );
    });
    return lineId;
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

  /// Le client du dossier d'une ligne : celui dont on photographie la piece
  /// a l'arrivee.
  Future<String?> guestIdOfLine(String lineId) async {
    final row = await db
        .customSelect(
          '''
      SELECT r.guest_id
        FROM reservation_rooms rr
        JOIN reservations r ON r.id = rr.reservation_id
       WHERE rr.id = ?1
      ''',
          variables: [Variable.withString(lineId)],
          readsFrom: {db.reservations, db.reservationRooms},
        )
        .getSingleOrNull();
    return row?.read<String?>('guest_id');
  }

  /// Enregistre l'arrivee (F1.2) : la chambre devient occupee et l'ardoise
  /// s'ouvre.
  ///
  /// Le folio est cree ici et non au depart : rien ne peut se consommer sans
  /// ardoise, et le client peut commander un cafe dans la minute qui suit son
  /// arrivee.
  ///
  /// Avec `surclassement`, le client prend `roomId`, une chambre d'une
  /// categorie superieure, au lieu de celle qui lui etait attribuee.
  Future<void> checkIn({
    required String lineId,
    String? by,
    String? roomId,
    Surclassement? surclassement,
    bool peutChangerTarif = false,
  }) async {
    final now = DateTime.now().toUtc();
    var line = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(lineId))).getSingle();

    ReservationRoomsCompanion? surclasse;
    if (surclassement != null) {
      if (roomId == null) {
        throw StateError('Choisissez la chambre du surclassement.');
      }
      await verifierSurclassement(
        lineId: lineId,
        roomId: roomId,
        surclassement: surclassement,
        peutChangerTarif: peutChangerTarif,
      );
      final chambre = await (db.select(
        db.rooms,
      )..where((r) => r.id.equals(roomId))).getSingle();
      if (chambre.isOutOfOrder || !chambre.isActive) {
        throw StateError('La chambre ${chambre.number} est hors service.');
      }
      if (chambre.occupancyStatus == OccupancyStatus.OCCUPIED) {
        throw StateError('La chambre ${chambre.number} est déjà occupée.');
      }
      surclasse = await _ecritureSurclassement(
        line,
        chambre,
        surclassement,
        by,
      );
      line = line.copyWith(roomId: Value(roomId));
    }

    if (line.roomId == null) {
      throw StateError(
        'Aucune chambre attribuee : impossible de prendre en charge cette '
        'arrivee.',
      );
    }

    final folioId = newId();
    final folioNumber = codeFromId(folioId, 'FOL');
    // Le client de l'ardoise, comme le serveur le pose au check-in : c'est
    // par lui que se lit le plafond de consommation. Sans lui, la tablette
    // laissait passer un depassement que le serveur refusait ensuite -- et
    // la file se bloquait.
    final dossier = await (db.select(
      db.reservations,
    )..where((r) => r.id.equals(line.reservationId))).getSingle();

    await db.transaction(() async {
      await (db.update(
        db.reservationRooms,
      )..where((rr) => rr.id.equals(lineId))).write(
        ReservationRoomsCompanion(
          status: const Value(ReservationStatus.CHECKED_IN),
          roomId: Value(line.roomId),
          checkedInAt: Value(now),
          checkedInBy: Value(by),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );
      if (surclasse != null) {
        await (db.update(
          db.reservationRooms,
        )..where((rr) => rr.id.equals(lineId))).write(surclasse);
      }

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
              guestId: Value(dossier.guestId),
              syncState: const Value(SyncState.pending),
            ),
          );

      // Les arrhes passent sur l'ardoise, comme le serveur le fait au
      // check-in : le client ne doit plus que le reste. Sans cela la tablette
      // affichait le sejour entier ; un encaissement du tout aurait ete
      // refuse en trop-percu par le serveur, et la file bloquee.
      await db.customUpdate(
        'UPDATE payments SET folio_id = ?1 '
        'WHERE folio_id IS NULL AND notes = ?2 AND deleted_at IS NULL',
        variables: [
          Variable.withString(folioId),
          Variable.withString(depositNote(dossier.reference)),
        ],
        updates: {db.payments},
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
          if (surclassement != null) 'room_id': line.roomId,
          if (surclassement != null) 'upgrade': surclassement.payload,
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
  /// Leve `StateError` si le depart ne peut pas avoir lieu.
  ///
  /// Un plateau en route vers la chambre : le serveur refuse le depart (sa
  /// livraison trouverait l'ardoise close), la tablette avant lui. Public
  /// pour que l'ecran le demande **avant** d'encaisser : refuse apres, le
  /// depart laissait un client qui avait paye toujours dans sa chambre.
  Future<void> verifierDepart(String lineId) async {
    for (final f
        in await (db.select(db.folios)..where(
              (f) => f.reservationRoomId.equals(lineId) & f.deletedAt.isNull(),
            ))
            .get()) {
      await RoomOrderRepository.verifierAucuneEnRoute(db, f.id, 'le départ');
    }
  }

  Future<void> checkOut({required String lineId, String? by}) async {
    final now = DateTime.now().toUtc();
    final line = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(lineId))).getSingle();
    await verifierDepart(lineId);

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

  /// Les refus de [annulerArrivee], sans rien ecrire : l'ecran les pose
  /// **avant** de demander le code du responsable, qui n'a pas a se deplacer
  /// pour un geste impossible.
  Future<void> verifierAnnulationArrivee(String lineId) =>
      _preparerAnnulationArrivee(lineId);

  Future<({ReservationRoomRow line, FolioRow? ardoise, String arrhes})>
  _preparerAnnulationArrivee(String lineId) async {
    final line = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(lineId))).getSingle();
    if (line.status != ReservationStatus.CHECKED_IN) {
      throw StateError("Ce séjour n'est pas en cours : rien à annuler.");
    }
    final dossier = await (db.select(
      db.reservations,
    )..where((r) => r.id.equals(line.reservationId))).getSingle();
    final arrhes = depositNote(dossier.reference);
    final ardoise =
        await (db.select(db.folios)..where(
              (f) => f.reservationRoomId.equals(lineId) & f.deletedAt.isNull(),
            ))
            .getSingleOrNull();

    if (ardoise != null) {
      // Une commande en route serait livree sur une ardoise retiree.
      await RoomOrderRepository.verifierAucuneEnRoute(
        db,
        ardoise.id,
        'd’annuler l’arrivée',
      );
      final encaisse = await db
          .customSelect(
            '''
            SELECT COALESCE(SUM(CASE WHEN is_refund = 1 THEN -amount
                                     ELSE amount END), 0) AS n
              FROM payments
             WHERE folio_id = ?1 AND deleted_at IS NULL
               AND COALESCE(notes, '') <> ?2
            ''',
            variables: [
              Variable.withString(ardoise.id),
              Variable.withString(arrhes),
            ],
            readsFrom: {db.payments},
          )
          .getSingle();
      if (encaisse.read<int>('n') != 0) {
        throw EncaissementsAAnnuler(dossier.guestId);
      }
      final autres = await db
          .customSelect(
            '''
            SELECT COUNT(*) AS n FROM folio_items
             WHERE folio_id = ?1 AND deleted_at IS NULL AND is_void = 0
               AND category <> 'ROOM'
            ''',
            variables: [Variable.withString(ardoise.id)],
            readsFrom: {db.folioItems},
          )
          .getSingle();
      if (autres.read<int>('n') > 0) {
        throw StateError(
          "Des consommations sont portées sur l'ardoise : l'arrivée ne peut "
          'plus être annulée.',
        );
      }
    }
    return (line: line, ardoise: ardoise, arrhes: arrhes);
  }

  /// Annule une arrivee enregistree par erreur (demande du 16 octobre).
  ///
  /// [approuvePar] est le responsable dont le code a ete saisi : le serveur
  /// reverifie son droit (`operations.undo`). Les refus du serveur sont
  /// repris ici, **avant** d'ecrire, sinon ils bloqueraient la file :
  ///
  /// - un encaissement sur l'ardoise s'annule d'abord (l'argent est dans un
  ///   tiroir) ;
  /// - une consommation portee empeche l'annulation (elle est sortie du
  ///   stock).
  ///
  /// La ligne redevient confirmee -- annulee pour une arrivee directe, qui
  /// n'avait pas de reservation --, la chambre libre, et l'ardoise est
  /// retiree : ses lignes annulees, ses arrhes rendues au dossier.
  Future<void> annulerArrivee({
    required String lineId,
    required String approuvePar,
    required String motif,
    String? by,
  }) async {
    final now = DateTime.now().toUtc();
    final (:line, :ardoise, :arrhes) = await _preparerAnnulationArrivee(
      lineId,
    );

    await db.transaction(() async {
      if (ardoise != null) {
        await (db.update(db.folioItems)..where(
              (i) =>
                  i.folioId.equals(ardoise.id) &
                  i.isVoid.equals(false) &
                  i.deletedAt.isNull(),
            ))
            .write(
              FolioItemsCompanion(
                isVoid: const Value(true),
                voidReason: Value(_borne('Arrivée annulée : $motif')),
                voidedBy: Value(approuvePar),
                updatedAt: Value(now),
              ),
            );
        // Les arrhes reviennent sur le dossier : une nouvelle arrivee les
        // fera basculer a nouveau, comme la premiere fois.
        if (!line.isWalkIn) {
          await db.customUpdate(
            'UPDATE payments SET folio_id = NULL '
            'WHERE folio_id = ?1 AND notes = ?2 AND is_refund = 0 '
            'AND deleted_at IS NULL',
            variables: [
              Variable.withString(ardoise.id),
              Variable.withString(arrhes),
            ],
            updates: {db.payments},
          );
        }
        await FolioRepository(db, hotelId: hotelId).recalculer(ardoise.id);
        // Retiree et non close : une nouvelle arrivee ouvrira une ardoise
        // neuve, comme cote serveur.
        await (db.update(
          db.folios,
        )..where((f) => f.id.equals(ardoise.id))).write(
          FoliosCompanion(deletedAt: Value(now), updatedAt: Value(now)),
        );
      }

      await (db.update(
        db.reservationRooms,
      )..where((rr) => rr.id.equals(lineId))).write(
        ReservationRoomsCompanion(
          status: Value(
            line.isWalkIn
                ? ReservationStatus.CANCELLED
                : ReservationStatus.CONFIRMED,
          ),
          checkedInAt: const Value(null),
          checkedInBy: const Value(null),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      if (line.roomId != null) {
        final ailleurs =
            await (db.select(db.reservationRooms)..where(
                  (rr) =>
                      rr.roomId.equals(line.roomId!) &
                      rr.id.equals(lineId).not() &
                      rr.status.equalsValue(ReservationStatus.CHECKED_IN) &
                      rr.deletedAt.isNull(),
                ))
                .get();
        if (ailleurs.isEmpty) {
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
      }

      await _recalculerStatutDossier(line.reservationId, now);

      await enqueue(
        table: 'reservation_rooms',
        id: lineId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': lineId,
          'action': 'UNDO_CHECK_IN',
          'approved_by': approuvePar,
          'reason': motif,
        },
      );
    });
  }

  /// Annule un depart enregistre par erreur : le client reprend sa chambre.
  ///
  /// Refuse si la chambre a deja ete redonnee, comme le serveur. L'ardoise
  /// se rouvre si elle avait ete close ; la chambre garde son etat de
  /// menage.
  Future<void> annulerDepart({
    required String lineId,
    required String approuvePar,
    required String motif,
  }) async {
    final now = DateTime.now().toUtc();
    final line = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(lineId))).getSingle();
    if (line.status != ReservationStatus.CHECKED_OUT) {
      throw StateError("Ce séjour n'est pas parti : rien à annuler.");
    }
    if (line.roomId != null) {
      final chambre = await (db.select(
        db.rooms,
      )..where((r) => r.id.equals(line.roomId!))).getSingleOrNull();
      if (chambre != null &&
          chambre.occupancyStatus == OccupancyStatus.OCCUPIED) {
        throw StateError(
          'La chambre ${chambre.number} est déjà occupée par un autre séjour.',
        );
      }
    }

    await db.transaction(() async {
      await (db.update(
        db.reservationRooms,
      )..where((rr) => rr.id.equals(lineId))).write(
        ReservationRoomsCompanion(
          status: const Value(ReservationStatus.CHECKED_IN),
          checkedOutAt: const Value(null),
          checkedOutBy: const Value(null),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );
      if (line.roomId != null) {
        await (db.update(
          db.rooms,
        )..where((r) => r.id.equals(line.roomId!))).write(
          RoomsCompanion(
            occupancyStatus: const Value(OccupancyStatus.OCCUPIED),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
      }
      await (db.update(db.folios)..where(
            (f) =>
                f.reservationRoomId.equals(lineId) &
                f.deletedAt.isNull() &
                f.status.equalsValue(FolioStatus.OPEN).not(),
          ))
          .write(
            FoliosCompanion(
              status: const Value(FolioStatus.OPEN),
              closedAt: const Value(null),
              updatedAt: Value(now),
            ),
          );
      await _recalculerStatutDossier(line.reservationId, now);

      await enqueue(
        table: 'reservation_rooms',
        id: lineId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': lineId,
          'action': 'UNDO_CHECK_OUT',
          'approved_by': approuvePar,
          'reason': motif,
        },
      );
    });
  }

  /// Le statut du dossier suit sa ligne la plus avancee, comme le serveur.
  Future<void> _recalculerStatutDossier(
    String reservationId,
    DateTime now,
  ) async {
    final lignes =
        await (db.select(db.reservationRooms)..where(
              (rr) =>
                  rr.reservationId.equals(reservationId) & rr.deletedAt.isNull(),
            ))
            .get();
    final statuts = lignes.map((l) => l.status).toSet();
    final statut = [
      ReservationStatus.CHECKED_IN,
      ReservationStatus.CONFIRMED,
      ReservationStatus.PENDING,
      ReservationStatus.CHECKED_OUT,
      ReservationStatus.NO_SHOW,
    ].firstWhere(statuts.contains, orElse: () => ReservationStatus.CANCELLED);
    await (db.update(
      db.reservations,
    )..where((r) => r.id.equals(reservationId))).write(
      ReservationsCompanion(
        status: Value(statut),
        updatedAt: Value(now),
        syncState: const Value(SyncState.pending),
      ),
    );
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
    Surclassement? surclassement,
    bool peutChangerTarif = false,
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
    ReservationRoomsCompanion? surclasse;
    if (surclassement != null) {
      await verifierSurclassement(
        lineId: lineId,
        roomId: roomId,
        surclassement: surclassement,
        peutChangerTarif: peutChangerTarif,
      );
      surclasse = await _ecritureSurclassement(line, room, surclassement, by);
    } else if (room.roomTypeId != line.roomTypeId) {
      throw StateError(
        'Cette chambre n\'appartient pas a la categorie reservee.',
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
      if (surclasse != null) {
        await (db.update(
          db.reservationRooms,
        )..where((rr) => rr.id.equals(lineId))).write(surclasse);
      }

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
          if (surclassement != null) 'upgrade': surclassement.payload,
        },
      );
    });
  }

  /// Les arrhes encaissees qu'une annulation ferait conserver, `null` s'il
  /// n'y en a pas. Le dialogue d'annulation le dit avant qu'on confirme.
  Future<int?> keptDeposit(String reservationId) async {
    final paiement = await _depositPayment(reservationId);
    return paiement?.amount;
  }

  /// Le paiement d'arrhes encore rattache au dossier : ni passe sur l'ardoise
  /// d'arrivee, ni deja conserve.
  Future<PaymentRow?> _depositPayment(String reservationId) async {
    final dossier = await (db.select(
      db.reservations,
    )..where((r) => r.id.equals(reservationId))).getSingleOrNull();
    if (dossier == null) return null;
    return (db.select(db.payments)..where(
          (p) =>
              p.folioId.isNull() &
              p.deletedAt.isNull() &
              p.notes.equals(depositNote(dossier.reference)),
        ))
        .getSingleOrNull();
  }

  /// Annule tout le dossier.
  ///
  /// Les arrhes encaissees restent acquises a l'hotel, comme cote serveur :
  /// elles deviennent une indemnite d'annulation sur une ardoise au nom du
  /// client, soldee et close aussitot. L'argent ne bouge pas de la caisse qui
  /// l'a recu ; il cesse seulement d'etre « en attente ».
  ///
  /// Le refus du serveur est verifie ici **avant** d'ecrire : un client deja
  /// arrive ne s'annule pas, il part (check-out).
  Future<void> cancel({
    required String reservationId,
    String? reason,
    String? by,
  }) async {
    final now = DateTime.now().toUtc();
    final dossier = await (db.select(
      db.reservations,
    )..where((r) => r.id.equals(reservationId))).getSingle();
    if (dossier.status == ReservationStatus.CANCELLED) return;

    final lignes = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(reservationId))).get();
    if (lignes.any((l) => l.status == ReservationStatus.CHECKED_IN)) {
      throw StateError(
        'Le client est déjà arrivé : enregistrez son départ plutôt que '
        "d'annuler.",
      );
    }

    final motif = reason?.trim();
    final arrhes = await _depositPayment(reservationId);
    final folioId = arrhes == null ? null : newId();

    await db.transaction(() async {
      await (db.update(
        db.reservations,
      )..where((r) => r.id.equals(reservationId))).write(
        ReservationsCompanion(
          status: const Value(ReservationStatus.CANCELLED),
          cancelledAt: Value(now),
          cancelReason: Value(motif == null || motif.isEmpty ? null : motif),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      for (final l in lignes) {
        if (l.status == ReservationStatus.CHECKED_OUT) continue;
        await (db.update(
          db.reservationRooms,
        )..where((rr) => rr.id.equals(l.id))).write(
          ReservationRoomsCompanion(
            status: const Value(ReservationStatus.CANCELLED),
            updatedAt: Value(now),
            updatedBy: Value(by),
          ),
        );
        // La chambre retenue redevient libre, sauf si un autre sejour
        // l'attend.
        if (l.roomId != null) await _releaseReserved(l.roomId!, l.id, now);
      }

      // L'indemnite, comme le serveur la pose : meme id d'ardoise, envoye
      // avec l'annulation. Pas enfilee a part : le serveur la cree lui-meme.
      if (arrhes != null) {
        await db
            .into(db.folios)
            .insert(
              FoliosCompanion.insert(
                id: folioId!,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                number: codeFromId(folioId, 'FOL'),
                type: const Value(FolioType.GUEST),
                status: const Value(FolioStatus.CLOSED),
                closedAt: Value(now),
                guestId: Value(dossier.guestId),
                chargesTotal: Value(arrhes.amount),
                paymentsTotal: Value(arrhes.amount),
                balance: const Value(0),
                notes: Value(
                  'Arrhes conservées - dossier ${dossier.reference} annulé',
                ),
                syncState: const Value(SyncState.synced),
              ),
            );
        await db
            .into(db.folioItems)
            .insert(
              FolioItemsCompanion.insert(
                id: newId(),
                createdAt: now,
                updatedAt: now,
                folioId: folioId,
                category: ChargeCategory.MISC,
                label: "Indemnité d'annulation - dossier ${dossier.reference}",
                unitPrice: Value(arrhes.amount),
                amount: Value(arrhes.amount),
                businessDate: businessDateNow(),
                sourceTable: const Value('reservations'),
                sourceId: Value(reservationId),
                postedBy: Value(by),
                syncState: const Value(SyncState.synced),
              ),
            );
        await (db.update(
          db.payments,
        )..where((p) => p.id.equals(arrhes.id))).write(
          PaymentsCompanion(folioId: Value(folioId), updatedAt: Value(now)),
        );
      }

      // `action` : le statut seul ne dit pas au serveur quel endpoint
      // appeler, et l'envoyeur prendrait l'entree pour une creation.
      await enqueue(
        table: 'reservations',
        id: reservationId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': reservationId,
          'action': 'CANCEL',
          'reason': motif == null || motif.isEmpty ? null : motif,
          'folio_id': folioId,
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

/// La note qui rattache des arrhes a leur dossier, le temps qu'elles
/// attendent l'ardoise ouverte a l'arrivee.
String depositNote(String reference) => 'Arrhes $reference';

/// Un motif tient en 255 caracteres, comme la colonne du serveur.
String _borne(String texte) =>
    texte.length <= 255 ? texte : texte.substring(0, 255);

/// L'arrivee ne s'annule pas tant que l'ardoise porte des encaissements :
/// l'argent est dans un tiroir. Porte le client, pour que l'ecran propose
/// d'aller les annuler sur sa fiche (demande du 24 octobre).
class EncaissementsAAnnuler extends StateError {
  EncaissementsAAnnuler(this.guestId)
    : super(
        "Des encaissements sont enregistrés sur l'ardoise : annulez-les "
        "d'abord.",
      );

  final String guestId;
}
