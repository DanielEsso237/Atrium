/// Lectures du serveur central.
///
/// Rien ici ne touche a l'interface : ces appels alimentent la base locale,
/// et ce sont les ecrans qui lisent ensuite Drift. Un widget qui importerait
/// ce fichier casserait le mode hors connexion.
library;

import 'api_client.dart';

/// Une chambre telle que le serveur la decrit (`RoomOut`).
///
/// Les champs suivent le schema exporte dans `docs/api/openapi.json` : la
/// categorie et l'etage arrivent imbriques, ce qui evite deux appels de plus.
class RemoteRoom {
  const RemoteRoom({
    required this.id,
    required this.number,
    required this.occupancyStatus,
    required this.housekeepingStatus,
    required this.isOutOfOrder,
    required this.roomTypeId,
    required this.roomTypeCode,
    required this.roomTypeLabel,
    required this.roomTypeRate,
    this.floorId,
    this.floorCode,
    this.floorLabel,
  });

  final String id;
  final String number;
  final String occupancyStatus;
  final String housekeepingStatus;
  final bool isOutOfOrder;

  final String roomTypeId;
  final String roomTypeCode;
  final String roomTypeLabel;
  final int roomTypeRate;

  final String? floorId;
  final String? floorCode;
  final String? floorLabel;

  static RemoteRoom? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['room_type'];
    if (type is! Map)
      return null; // sans categorie, la chambre est inexploitable
    final floor = raw['floor'];

    return RemoteRoom(
      id: '${raw['id']}',
      number: '${raw['number']}',
      occupancyStatus: '${raw['occupancy_status']}',
      housekeepingStatus: '${raw['housekeeping_status']}',
      isOutOfOrder: raw['is_out_of_order'] == true,
      roomTypeId: '${type['id']}',
      roomTypeCode: '${type['code']}',
      roomTypeLabel: '${type['label']}',
      // Entier en francs CFA, conformement au contrat. Jamais de double en
      // chemin : `num.toInt()` et non `double.parse`.
      roomTypeRate: (type['default_rate'] as num?)?.toInt() ?? 0,
      floorId: floor is Map ? '${floor['id']}' : null,
      floorCode: floor is Map ? '${floor['code']}' : null,
      floorLabel: floor is Map ? '${floor['label']}' : null,
    );
  }
}

class CatalogApi {
  const CatalogApi(this._client);

  final ApiClient _client;

  /// Le parc de chambres, avec categories et etages.
  ///
  /// Une ligne illisible est ignoree plutot que de faire echouer tout le
  /// lot : une chambre mal formee ne doit pas priver la reception des
  /// dix-sept autres.
  Future<List<RemoteRoom>> fetchRooms() async {
    final data = await _client.getList('/rooms');
    return data
        .map(RemoteRoom.fromJson)
        .whereType<RemoteRoom>()
        .toList(growable: false);
  }
}
