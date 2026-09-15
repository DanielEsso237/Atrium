/// Lectures du module hebergement.
///
/// Deux vues, qui sont celles des ecrans du cahier des charges : le
/// regroupement par categorie (paramétrage et grille tarifaire) et le plan de
/// l'hotel (paragraphe 5.2).
library;

import 'package:drift/drift.dart';

import '../database.dart';
import '../enums.dart';

/// Une categorie et son parc de chambres.
class RoomTypeSummary {
  const RoomTypeSummary({
    required this.typeId,
    required this.code,
    required this.label,

    /// Tarif de reference de la categorie, en francs CFA entiers.
    required this.rate,
    required this.roomCount,
    required this.numbers,
  });

  final String typeId;
  final String code;
  final String label;
  final int rate;
  final int roomCount;

  /// Numeros des chambres de cette categorie, tries.
  final List<String> numbers;

  @override
  String toString() =>
      '$label ($code) — $rate FCFA — $roomCount chambres : ${numbers.join(", ")}';
}

/// Une chambre telle qu'affichee sur le plan de l'hotel.
class RoomBoardEntry {
  const RoomBoardEntry({
    required this.roomId,
    required this.number,
    required this.typeCode,
    required this.typeLabel,
    required this.rate,
    required this.floorLabel,
    required this.occupancy,
    required this.housekeeping,
    required this.isOutOfOrder,
  });

  final String roomId;
  final String number;
  final String typeCode;
  final String typeLabel;
  final int rate;
  final String? floorLabel;
  final OccupancyStatus occupancy;
  final HousekeepingStatus housekeeping;
  final bool isOutOfOrder;

  /// La pastille de couleur de l'ecran 5.2.
  ///
  /// Elle n'est pas stockee : elle se calcule a partir des trois axes
  /// independants de la chambre, par ordre de priorite decroissante. Stocker
  /// un etat unique ferait que la reception et le housekeeping s'ecraseraient
  /// mutuellement, puisqu'ils ecriraient la meme colonne pour deux raisons
  /// differentes.
  RoomDisplayStatus get displayStatus {
    if (isOutOfOrder) return RoomDisplayStatus.MAINTENANCE;
    if (occupancy == OccupancyStatus.OCCUPIED) return RoomDisplayStatus.OCCUPIED;
    if (housekeeping == HousekeepingStatus.DIRTY ||
        housekeeping == HousekeepingStatus.IN_PROGRESS) {
      return RoomDisplayStatus.CLEANING;
    }
    if (occupancy == OccupancyStatus.RESERVED) return RoomDisplayStatus.RESERVED;
    return RoomDisplayStatus.AVAILABLE;
  }
}

extension RoomsQueries on AtriumDatabase {
  /// Les categories avec leur tarif et la liste de leurs chambres.
  ///
  /// C'est la lecture du parametrage : « quelles categories existent, a quel
  /// prix, et quelles chambres en font partie ».
  Future<List<RoomTypeSummary>> roomTypeSummaries() async {
    final rows = await customSelect(
      '''
      SELECT rt.id, rt.code, rt.label, rt.default_rate, rt.sort_order,
             COUNT(r.id)                       AS room_count,
             GROUP_CONCAT(r.number, ',')       AS numbers
        FROM room_types rt
        LEFT JOIN rooms r
               ON r.room_type_id = rt.id
              AND r.deleted_at IS NULL
              AND r.is_active = 1
       WHERE rt.deleted_at IS NULL AND rt.is_active = 1
       GROUP BY rt.id
       ORDER BY rt.default_rate
      ''',
      readsFrom: {roomTypes, rooms},
    ).get();

    return rows.map((row) {
      final raw = row.read<String?>('numbers');
      final numbers = (raw == null || raw.isEmpty) ? <String>[] : raw.split(',')
        ..sort();
      return RoomTypeSummary(
        typeId: row.read<String>('id'),
        code: row.read<String>('code'),
        label: row.read<String>('label'),
        rate: row.read<int>('default_rate'),
        roomCount: row.read<int>('room_count'),
        numbers: numbers,
      );
    }).toList();
  }

  /// Le plan de l'hotel : toutes les chambres avec leur etat courant.
  ///
  /// Requete unique et sans agregat sur les reservations : l'ecran doit se
  /// peindre instantanement, hors ligne, sur une tablette posee au comptoir.
  /// C'est la raison d'etre des colonnes d'etat materialisees sur `rooms`.
  Stream<List<RoomBoardEntry>> watchRoomBoard() {
    return customSelect(
      '''
      SELECT r.id, r.number, r.occupancy_status, r.housekeeping_status,
             r.is_out_of_order,
             rt.code AS type_code, rt.label AS type_label,
             rt.default_rate,
             f.label AS floor_label, f.sort_order AS floor_order
        FROM rooms r
        JOIN room_types rt ON rt.id = r.room_type_id
        LEFT JOIN floors f ON f.id = r.floor_id
       WHERE r.deleted_at IS NULL AND r.is_active = 1
       ORDER BY f.sort_order, r.number
      ''',
      readsFrom: {rooms, roomTypes, floors},
    ).watch().map(
          (rows) => rows
              .map(
                (row) => RoomBoardEntry(
                  roomId: row.read<String>('id'),
                  number: row.read<String>('number'),
                  typeCode: row.read<String>('type_code'),
                  typeLabel: row.read<String>('type_label'),
                  rate: row.read<int>('default_rate'),
                  floorLabel: row.read<String?>('floor_label'),
                  occupancy: OccupancyStatus.values.byName(
                    row.read<String>('occupancy_status'),
                  ),
                  housekeeping: HousekeepingStatus.values.byName(
                    row.read<String>('housekeeping_status'),
                  ),
                  isOutOfOrder: row.read<int>('is_out_of_order') == 1,
                ),
              )
              .toList(),
        );
  }

  /// Chambres disponibles d'une categorie sur une periode donnee.
  ///
  /// Le test de chevauchement porte sur un intervalle **semi-ouvert** :
  /// un sejour du 12 au 15 occupe les nuits du 12, 13 et 14 et libere la
  /// chambre le 15. Deux sejours se chevauchent donc si `A1 < D2 ET D1 > A2`.
  /// Ecrire `<=` inventerait un conflit entre un depart et une arrivee le meme
  /// jour, soit une chambre invendable par jour et par rotation.
  Future<List<String>> availableRoomNumbers({
    required String roomTypeId,
    required String arrival,
    required String departure,
  }) async {
    final rows = await customSelect(
      '''
      SELECT r.number
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
        Variable.withString(arrival),
        Variable.withString(departure),
      ],
      readsFrom: {rooms, reservationRooms},
    ).get();

    return rows.map((r) => r.read<String>('number')).toList();
  }
}
