/// Lectures du serveur central.
///
/// Rien ici ne touche a l'interface : ces appels alimentent la base locale,
/// et ce sont les ecrans qui lisent ensuite Drift. Un widget qui importerait
/// ce fichier casserait le mode hors connexion.
///
/// Chaque modele est **defensif** : une ligne illisible est ignoree plutot que
/// de faire echouer tout le lot. Une reservation mal formee ne doit pas priver
/// la reception des quarante autres.
library;

import 'api_client.dart';

/// Une chaine, ou `null` si le champ est absent.
///
/// Interpoler directement rendrait la chaine « null » sur un champ absent, et
/// cette chaine-la passerait ensuite pour une vraie valeur jusque dans la base.
String? _texte(Object? v) => v == null ? null : '$v';

DateTime? _instant(Object? v) =>
    v == null ? null : DateTime.tryParse('$v')?.toUtc();

int _entier(Object? v, [int parDefaut = 0]) =>
    (v as num?)?.toInt() ?? parDefaut;

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
    // Sans categorie, la chambre est inexploitable.
    if (type is! Map) return null;
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
      // chemin.
      roomTypeRate: _entier(type['default_rate']),
      floorId: floor is Map ? '${floor['id']}' : null,
      floorCode: floor is Map ? '${floor['code']}' : null,
      floorLabel: floor is Map ? '${floor['label']}' : null,
    );
  }
}

/// Un client (`GuestOut`).
class RemoteGuest {
  const RemoteGuest({
    required this.id,
    required this.code,
    required this.firstName,
    required this.lastName,
    this.phone,
    this.email,
    this.nationality,
    this.documentType,
    this.documentNumber,
    this.isVip = false,
  });

  final String id;
  final String code;
  final String firstName;
  final String lastName;
  final String? phone;
  final String? email;
  final String? nationality;
  final String? documentType;
  final String? documentNumber;
  final bool isVip;

  static RemoteGuest? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null || raw['code'] == null) return null;
    return RemoteGuest(
      id: '${raw['id']}',
      code: '${raw['code']}',
      firstName: '${raw['first_name'] ?? ''}',
      lastName: '${raw['last_name'] ?? ''}',
      phone: _texte(raw['phone']),
      email: _texte(raw['email']),
      nationality: _texte(raw['nationality']),
      documentType: _texte(raw['id_document_type']),
      documentNumber: _texte(raw['id_document_number']),
      isVip: raw['is_vip'] == true,
    );
  }
}

/// Une ligne de sejour (`ReservationRoomOut`).
class RemoteStayLine {
  const RemoteStayLine({
    required this.id,
    required this.roomTypeId,
    required this.status,
    required this.arrivalDate,
    required this.departureDate,
    required this.adults,
    required this.children,
    required this.nightlyRate,
    this.roomId,
    this.checkedInAt,
    this.checkedOutAt,
  });

  final String id;
  final String roomTypeId;
  final String status;
  final String arrivalDate;
  final String departureDate;
  final int adults;
  final int children;
  final int nightlyRate;
  final String? roomId;
  final DateTime? checkedInAt;
  final DateTime? checkedOutAt;

  static RemoteStayLine? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null || raw['room_type_id'] == null) {
      return null;
    }
    return RemoteStayLine(
      id: '${raw['id']}',
      roomTypeId: '${raw['room_type_id']}',
      status: '${raw['status']}',
      arrivalDate: '${raw['arrival_date']}',
      departureDate: '${raw['departure_date']}',
      adults: _entier(raw['adults'], 1),
      children: _entier(raw['children']),
      nightlyRate: _entier(raw['nightly_rate']),
      roomId: _texte(raw['room_id']),
      checkedInAt: _instant(raw['checked_in_at']),
      checkedOutAt: _instant(raw['checked_out_at']),
    );
  }
}

/// Un dossier de reservation (`ReservationOut`), avec ses lignes.
class RemoteReservation {
  const RemoteReservation({
    required this.id,
    required this.reference,
    required this.guestId,
    required this.status,
    required this.arrivalDate,
    required this.departureDate,
    required this.adults,
    required this.children,
    required this.rooms,
  });

  final String id;
  final String reference;
  final String guestId;
  final String status;
  final String arrivalDate;
  final String departureDate;
  final int adults;
  final int children;
  final List<RemoteStayLine> rooms;

  static RemoteReservation? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null || raw['guest_id'] == null) {
      return null;
    }
    return RemoteReservation(
      id: '${raw['id']}',
      reference: '${raw['reference'] ?? ''}',
      guestId: '${raw['guest_id']}',
      status: '${raw['status']}',
      arrivalDate: '${raw['arrival_date']}',
      departureDate: '${raw['departure_date']}',
      adults: _entier(raw['adults'], 1),
      children: _entier(raw['children']),
      rooms: (raw['rooms'] as List? ?? const [])
          .map(RemoteStayLine.fromJson)
          .whereType<RemoteStayLine>()
          .toList(growable: false),
    );
  }
}

/// Une ligne d'ardoise (`FolioItemOut`).
class RemoteFolioItem {
  const RemoteFolioItem({
    required this.id,
    required this.category,
    required this.label,
    required this.quantity,
    required this.unitPrice,
    required this.amount,
    required this.businessDate,
    this.taxRate = 0,
    this.taxAmount = 0,
    this.isVoid = false,
  });

  final String id;
  final String category;
  final String label;
  final int quantity;
  final int unitPrice;
  final int amount;
  final String businessDate;
  final int taxRate;
  final int taxAmount;
  final bool isVoid;

  static RemoteFolioItem? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null) return null;
    return RemoteFolioItem(
      id: '${raw['id']}',
      category: '${raw['category']}',
      label: '${raw['label'] ?? ''}',
      quantity: _entier(raw['quantity'], 1),
      unitPrice: _entier(raw['unit_price']),
      amount: _entier(raw['amount']),
      businessDate: '${raw['business_date']}',
      taxRate: _entier(raw['tax_rate']),
      taxAmount: _entier(raw['tax_amount']),
      isVoid: raw['is_void'] == true,
    );
  }
}

/// Une ardoise (`FolioOut`), avec ses lignes.
///
/// **Les encaissements n'y sont pas** : le schema du serveur ne les expose
/// pas. Les totaux et le solde, si — donc l'ardoise s'affiche juste, mais le
/// detail des paiements ne descend pas. Sans consequence tant que la tablette
/// qui encaisse est celle qui affiche ; a reprendre le jour ou deux postes se
/// partagent une meme ardoise.
class RemoteFolio {
  const RemoteFolio({
    required this.id,
    required this.number,
    required this.status,
    required this.type,
    required this.chargesTotal,
    required this.paymentsTotal,
    required this.balance,
    required this.items,
    this.guestId,
    this.stayLineId,
    this.openedAt,
    this.closedAt,
  });

  final String id;
  final String number;
  final String status;
  final String type;
  final int chargesTotal;
  final int paymentsTotal;
  final int balance;
  final List<RemoteFolioItem> items;
  final String? guestId;
  final String? stayLineId;
  final DateTime? openedAt;
  final DateTime? closedAt;

  static RemoteFolio? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null) return null;
    return RemoteFolio(
      id: '${raw['id']}',
      number: '${raw['number'] ?? ''}',
      status: '${raw['status']}',
      type: '${raw['type']}',
      chargesTotal: _entier(raw['charges_total']),
      paymentsTotal: _entier(raw['payments_total']),
      balance: _entier(raw['balance']),
      items: (raw['items'] as List? ?? const [])
          .map(RemoteFolioItem.fromJson)
          .whereType<RemoteFolioItem>()
          .toList(growable: false),
      guestId: _texte(raw['guest_id']),
      stayLineId: _texte(raw['reservation_room_id']),
      openedAt: _instant(raw['opened_at']),
      closedAt: _instant(raw['closed_at']),
    );
  }
}

class CatalogApi {
  const CatalogApi(this._client);

  final ApiClient _client;

  /// Le parc de chambres, avec categories et etages.
  Future<List<RemoteRoom>> fetchRooms() => _lire('/rooms', RemoteRoom.fromJson);

  /// Les clients de l'hotel.
  ///
  /// Sans filtre : le serveur ne propose qu'une recherche texte, et le fichier
  /// client d'un hotel de cette taille tient largement. A revoir le jour ou il
  /// se comptera en dizaines de milliers.
  Future<List<RemoteGuest>> fetchGuests() =>
      _lire('/guests', RemoteGuest.fromJson);

  /// Les reservations d'une fenetre de dates.
  ///
  /// **Bornee, jamais tout.** Sans filtre de date de modification cote
  /// serveur, chaque descente relit ce qu'elle demande : demander tout ferait
  /// grossir l'appel avec l'historique de l'hotel, indefiniment. La fenetre
  /// par defaut couvre les departs recents et les arrivees a venir.
  Future<List<RemoteReservation>> fetchReservations({
    DateTime? from,
    DateTime? to,
    int joursAvant = 7,
    int joursApres = 30,
  }) {
    final aujourdhui = DateTime.now();
    final debut = from ?? aujourdhui.subtract(Duration(days: joursAvant));
    final fin = to ?? aujourdhui.add(Duration(days: joursApres));

    return _lire('/reservations', RemoteReservation.fromJson, query: {
      'arrival_from': _jour(debut),
      'arrival_to': _jour(fin),
    });
  }

  /// Les ardoises ouvertes, avec leurs lignes.
  ///
  /// Les ardoises closes ne descendent pas : elles ne bougent plus, et les
  /// rapatrier ferait grossir l'appel sans rien apporter a la reception.
  Future<List<RemoteFolio>> fetchOpenFolios() =>
      _lire('/folios', RemoteFolio.fromJson, query: {'status': 'OPEN'});

  /// Lit une liste et en ecarte les lignes illisibles.
  Future<List<T>> _lire<T>(
    String chemin,
    T? Function(Object?) depuisJson, {
    Map<String, dynamic>? query,
  }) async {
    final data = await _client.getList(chemin, query: query);
    return data.map(depuisJson).whereType<T>().toList(growable: false);
  }

  /// Une date seule, `AAAA-MM-JJ`, comme l'exige le contrat.
  static String _jour(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
