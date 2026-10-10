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

import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_client.dart';

/// Une chaine, ou `null` si le champ est absent.
///
/// Interpoler directement rendrait la chaine « null » sur un champ absent, et
/// cette chaine-la passerait ensuite pour une vraie valeur jusque dans la base.
String? _texte(Object? v) => v == null ? null : '$v';

/// Une heure en HH:MM. Le serveur ecrit `08:00:00` ; la colonne locale n'en
/// garde que cinq caracteres, et refuserait le reste.
String? _heure(Object? v) {
  final t = _texte(v);
  return t == null || t.length <= 5 ? t : t.substring(0, 5);
}

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

/// Un point de vente (`OutletOut`) : restaurant, bar, piscine, boite de nuit.
///
/// C'est cette table qui engendre les onglets de l'ecran Commande. Les ecrire
/// en dur ferait d'un ajout de point de vente une livraison de l'application,
/// alors que c'est un geste d'administration.
class RemoteOutlet {
  const RemoteOutlet({
    required this.id,
    required this.code,
    required this.label,
    required this.allowsRoomCharge,
    required this.sortOrder,
    this.opensAt,
    this.closesAt,
    this.isActive = true,
    this.kind = 'OUTLET',
  });

  final String id;
  final String code;
  final String label;

  /// Desactive par l'administration : il sort des onglets de l'ecran
  /// Commande, mais reste en base -- les commandes passees y renvoient.
  final bool isActive;

  /// `OUTLET` ou `SERVICE`.
  final String kind;

  /// Ce point de vente peut-il porter une consommation sur la chambre.
  ///
  /// Une boutique qui encaisse comptant ne le peut pas : sa vente n'a rien a
  /// faire sur l'ardoise d'un sejour.
  final bool allowsRoomCharge;

  final int sortOrder;
  final String? opensAt;
  final String? closesAt;

  static RemoteOutlet? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null || raw['code'] == null) return null;
    return RemoteOutlet(
      id: '${raw['id']}',
      code: '${raw['code']}',
      label: '${raw['label'] ?? raw['code']}',
      allowsRoomCharge: raw['allows_room_charge'] != false,
      sortOrder: _entier(raw['sort_order']),
      opensAt: _heure(raw['opens_at']),
      closesAt: _heure(raw['closes_at']),
      isActive: raw['is_active'] != false,
      kind: '${raw['kind'] ?? 'OUTLET'}',
    );
  }
}

/// Une categorie de la carte (`MenuCategoryOut`) : Plats, Boissons, Desserts...
///
/// `outletId` nul veut dire une categorie commune a tous les points de vente.
/// Le serveur ne filtre pas la carte par point de vente : c'est la tablette
/// qui le fait, en lisant ce champ.
class RemoteMenuCategory {
  const RemoteMenuCategory({
    required this.id,
    required this.label,
    required this.sortOrder,
    this.outletId,
  });

  final String id;
  final String label;
  final int sortOrder;
  final String? outletId;

  static RemoteMenuCategory? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null || raw['label'] == null) return null;
    return RemoteMenuCategory(
      id: '${raw['id']}',
      label: '${raw['label']}',
      sortOrder: _entier(raw['sort_order']),
      outletId: _texte(raw['outlet_id']),
    );
  }
}

/// Un article de la carte (`MenuItemOut`).
class RemoteMenuItem {
  const RemoteMenuItem({
    required this.id,
    required this.code,
    required this.label,
    required this.menuCategoryId,
    required this.price,
    required this.taxRate,
    required this.isAvailable,
    this.prepStationId,
    this.productId,
    this.stockQuantity = 1,
  });

  final String id;
  final String code;
  final String label;
  final String menuCategoryId;

  /// Le produit en stock que la vente consomme, et combien par article.
  final String? productId;
  final int stockQuantity;

  /// Entier en francs CFA, conformement au contrat. Jamais de double.
  final int price;

  /// Un pourcentage de 0 a 100 (et non des points de base : c'est ce que
  /// valide le serveur et ce que `orders.py` divise par 100). A stocker tel
  /// quel, sans conversion.
  final int taxRate;

  /// `false` = rupture : l'article reste dans la carte mais ne se vend plus.
  final bool isAvailable;

  /// Nul pour un article sans preparation (un droit d'entree, par exemple).
  final String? prepStationId;

  static RemoteMenuItem? fromJson(Object? raw) {
    if (raw is! Map ||
        raw['id'] == null ||
        raw['menu_category_id'] == null ||
        raw['label'] == null) {
      return null;
    }
    return RemoteMenuItem(
      id: '${raw['id']}',
      code: '${raw['code'] ?? ''}',
      label: '${raw['label']}',
      menuCategoryId: '${raw['menu_category_id']}',
      price: _entier(raw['price']),
      taxRate: _entier(raw['tax_rate']),
      isAvailable: raw['is_available'] != false,
      prepStationId: _texte(raw['prep_station_id']),
      productId: _texte(raw['product_id']),
      stockQuantity: _entier(raw['stock_quantity'], 1),
    );
  }
}

/// Un produit stocke (`ProductOut`) : biere, savon, serviette.
class RemoteProduct {
  const RemoteProduct({
    required this.id,
    required this.reference,
    required this.label,
    required this.unit,
    required this.purchasePrice,
    required this.salePrice,
    required this.minStock,
    this.categoryId,
  });

  final String id;
  final String reference;
  final String label;
  final String unit;

  /// Francs CFA entiers.
  final int purchasePrice;
  final int salePrice;

  /// Seuil d'alerte : en dessous, l'econome est prevenu.
  final int minStock;
  final String? categoryId;

  static RemoteProduct? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null || raw['label'] == null) return null;
    return RemoteProduct(
      id: '${raw['id']}',
      reference: '${raw['reference'] ?? ''}',
      label: '${raw['label']}',
      unit: '${raw['unit'] ?? 'U'}',
      purchasePrice: _entier(raw['purchase_price']),
      salePrice: _entier(raw['sale_price']),
      minStock: _entier(raw['min_stock']),
      categoryId: _texte(raw['category_id']),
    );
  }
}

/// Un magasin (`StockLocationOut`) : l'economat, ou le stock d'un point de
/// vente.
class RemoteStockLocation {
  const RemoteStockLocation({
    required this.id,
    required this.code,
    required this.label,
    required this.sortOrder,
    required this.isCentral,
    this.outletId,
  });

  final String id;
  final String code;
  final String label;
  final int sortOrder;
  final bool isCentral;
  final String? outletId;

  static RemoteStockLocation? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null || raw['label'] == null) return null;
    return RemoteStockLocation(
      id: '${raw['id']}',
      code: '${raw['code'] ?? ''}',
      label: '${raw['label']}',
      sortOrder: _entier(raw['sort_order']),
      isCentral: raw['is_central'] == true,
      outletId: _texte(raw['outlet_id']),
    );
  }
}

/// La quantite d'un produit dans un magasin (`StockLevelOut`).
class RemoteStockLevel {
  const RemoteStockLevel({
    required this.productId,
    required this.locationId,
    required this.quantity,
    this.lastMovementAt,
  });

  final String productId;
  final String locationId;

  /// Peut etre negative : le stock est theorique, et une vente ne se refuse
  /// pas pour autant (decision du 8 octobre).
  final int quantity;
  final DateTime? lastMovementAt;

  static RemoteStockLevel? fromJson(Object? raw) {
    if (raw is! Map || raw['product_id'] == null || raw['stock_location_id'] == null) {
      return null;
    }
    return RemoteStockLevel(
      productId: '${raw['product_id']}',
      locationId: '${raw['stock_location_id']}',
      quantity: _entier(raw['quantity']),
      lastMovementAt: _instant(raw['last_movement_at']),
    );
  }
}

/// Un mouvement de stock (`StockMovementOut`). Seuls les transferts en
/// attente descendent : ce sont eux que le controleur ou le comptable valide.
class RemoteStockMovement {
  const RemoteStockMovement({
    required this.id,
    required this.productId,
    required this.locationId,
    required this.type,
    required this.quantity,
    required this.status,
    this.counterpartLocationId,
    this.reason,
    this.movedAt,
    this.movedBy,
  });

  final String id;
  final String productId;
  final String locationId;
  final String type;
  final int quantity;
  final String status;
  final String? counterpartLocationId;
  final String? reason;
  final DateTime? movedAt;
  final String? movedBy;

  static RemoteStockMovement? fromJson(Object? raw) {
    if (raw is! Map ||
        raw['id'] == null ||
        raw['product_id'] == null ||
        raw['stock_location_id'] == null ||
        raw['type'] == null) {
      return null;
    }
    return RemoteStockMovement(
      id: '${raw['id']}',
      productId: '${raw['product_id']}',
      locationId: '${raw['stock_location_id']}',
      type: '${raw['type']}',
      quantity: _entier(raw['quantity']),
      status: '${raw['status'] ?? 'APPROVED'}',
      counterpartLocationId: _texte(raw['counterpart_location_id']),
      reason: _texte(raw['reason']),
      movedAt: _instant(raw['moved_at']),
      movedBy: _texte(raw['moved_by']),
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
    this.creditLimit = 0,
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

  /// Plafond de consommation a credit. `0` veut dire pas de limite.
  ///
  /// Doit descendre : sans lui la tablette ignorerait les seuils fixes
  /// ailleurs, et laisserait passer des consommations que le serveur
  /// refuserait ensuite -- ce qui bloquerait sa file d'envoi.
  final int creditLimit;

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
      creditLimit: _entier(raw['credit_limit']),
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
    this.depositAmount = 0,
    this.depositPaidAt,
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

  /// Les arrhes demandees (`deposit_amount`), et quand elles ont ete
  /// encaissees -- `null` tant qu'elles sont dues.
  final int depositAmount;
  final DateTime? depositPaidAt;

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
      depositAmount: _entier(raw['deposit_amount']),
      depositPaidAt: _instant(raw['deposit_paid_at']),
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
    this.sourceTable,
    this.sourceId,
    this.postedBy,
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

  /// L'origine de la ligne : `outlets` + l'id du point de vente pour une
  /// vente. Sans elle, les rapports d'un autre poste ne savent pas ou ranger
  /// la vente.
  final String? sourceTable;
  final String? sourceId;

  /// L'agent qui a saisi la ligne.
  final String? postedBy;

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
      sourceTable: _texte(raw['source_table']),
      sourceId: _texte(raw['source_id']),
      postedBy: _texte(raw['posted_by']),
    );
  }
}

/// Un encaissement (`PaymentOut`), pour les rapports.
class RemotePayment {
  const RemotePayment({
    required this.id,
    required this.method,
    required this.amount,
    this.isRefund = false,
    this.folioId,
    this.receivedBy,
    this.receivedAt,
    this.businessDate,
    this.cashSessionId,
    this.reference,
  });

  final String id;
  final String method;
  final int amount;
  final bool isRefund;
  final String? folioId;
  final String? receivedBy;
  final DateTime? receivedAt;

  /// Date seule, `AAAA-MM-JJ` : jamais convertie de fuseau.
  final String? businessDate;
  final String? cashSessionId;
  final String? reference;

  static RemotePayment? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null || raw['method'] == null) {
      return null;
    }
    return RemotePayment(
      id: '${raw['id']}',
      method: '${raw['method']}',
      amount: _entier(raw['amount']),
      isRefund: raw['is_refund'] == true,
      folioId: _texte(raw['folio_id']),
      receivedBy: _texte(raw['received_by']),
      receivedAt: _instant(raw['received_at']),
      businessDate: _texte(raw['business_date']),
      cashSessionId: _texte(raw['cash_session_id']),
      reference: _texte(raw['reference']),
    );
  }
}

/// Une caisse (`CashSessionOut`), pour le rapport du soir.
class RemoteCashSession {
  const RemoteCashSession({
    required this.id,
    required this.userId,
    required this.status,
    this.openedAt,
    this.openingFloat = 0,
    this.closedAt,
    this.expectedAmount = 0,
    this.countedAmount,
    this.variance = 0,
    this.outletId,
    this.receivedAmount,
    this.receivedBy,
    this.receivedAt,
    this.receivedSessionId,
  });

  final String id;
  final String userId;
  final String status;
  final DateTime? openedAt;
  final int openingFloat;
  final DateTime? closedAt;
  final int expectedAmount;
  final int? countedAmount;
  final int variance;

  /// Le point de vente dont c'est le tiroir ; nul pour la caisse centrale.
  final String? outletId;
  final int? receivedAmount;
  final String? receivedBy;
  final DateTime? receivedAt;
  final String? receivedSessionId;

  static RemoteCashSession? fromJson(Object? raw) {
    if (raw is! Map ||
        raw['id'] == null ||
        raw['user_id'] == null ||
        raw['status'] == null) {
      return null;
    }
    return RemoteCashSession(
      id: '${raw['id']}',
      userId: '${raw['user_id']}',
      status: '${raw['status']}',
      openedAt: _instant(raw['opened_at']),
      openingFloat: _entier(raw['opening_float']),
      closedAt: _instant(raw['closed_at']),
      expectedAmount: _entier(raw['expected_amount']),
      countedAmount: raw['counted_amount'] == null
          ? null
          : _entier(raw['counted_amount']),
      variance: _entier(raw['variance']),
      outletId: _texte(raw['outlet_id']),
      receivedAmount: raw['received_amount'] == null
          ? null
          : _entier(raw['received_amount']),
      receivedBy: _texte(raw['received_by']),
      receivedAt: _instant(raw['received_at']),
      receivedSessionId: _texte(raw['received_session_id']),
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

  /// Les points de vente, dans leur ordre d'affichage.
  ///
  /// Le serveur ne renvoie pas `is_active` : tout ce qui descend est donc
  /// considere actif. Le jour ou l'administration permettra d'en desactiver
  /// un, il faudra que le schema l'expose — sans quoi l'onglet resterait
  /// visible sur les tablettes.
  /// Les agents, bruts (`UserOut`) : roles avec permissions, points de vente.
  ///
  /// Reserve a qui porte `users.read` -- l'administration. Les autres postes
  /// apprennent chaque agent a sa connexion (`/auth/me`).
  Future<List<Map<String, dynamic>>> fetchUsers() async => [
    for (final u in await _client.getList('/users'))
      if (u is Map<String, dynamic>) u,
  ];

  /// Les roles avec leurs permissions, et le catalogue des permissions.
  /// Reserves a `users.read`, comme la liste des agents.
  Future<List<Map<String, dynamic>>> fetchRoles() async => [
    for (final r in await _client.getList('/roles'))
      if (r is Map<String, dynamic>) r,
  ];

  Future<List<Map<String, dynamic>>> fetchPermissions() async => [
    for (final p in await _client.getList('/permissions'))
      if (p is Map<String, dynamic>) p,
  ];

  /// La regle des arrhes, telle que le serveur la tient (`null` : aucune).
  ///
  /// Brute, en JSON : c'est `DepositRule.fromJson` qui la lit, la meme
  /// lecture que pour ce que la tablette ecrit elle-meme.
  Future<Object?> fetchDepositRule() async =>
      (await _client.get('/settings/deposit-rule'))['rule'];

  /// Les niveaux des alertes, bruts : `NiveauxAlertes.fromJson` les lit.
  /// `null` quand le serveur ne connait pas encore la route : la tablette
  /// garde alors ce qu'elle a.
  Future<Object?> fetchNotificationLevels() async {
    try {
      return (await _client.get('/settings/notification-levels'))['levels'];
    } on ApiException catch (e) {
      if (e.failure == ApiFailure.notFound) return null;
      rethrow;
    }
  }

  Future<List<RemoteOutlet>> fetchOutlets() =>
      _lire('/outlets', RemoteOutlet.fromJson);

  /// Les categories de la carte, dans leur ordre d'affichage.
  Future<List<RemoteMenuCategory>> fetchMenuCategories() =>
      _lire('/menu-categories', RemoteMenuCategory.fromJson);

  /// Les articles de la carte.
  Future<List<RemoteMenuItem>> fetchMenuItems() =>
      _lire('/menu-items', RemoteMenuItem.fromJson);

  /// Les produits stockes.
  Future<List<RemoteProduct>> fetchProducts() =>
      _lire('/products', RemoteProduct.fromJson);

  /// Les magasins : l'economat et le stock de chaque point de vente.
  Future<List<RemoteStockLocation>> fetchStockLocations() =>
      _lire('/stock-locations', RemoteStockLocation.fromJson);

  /// Les quantites de chaque produit dans chaque magasin.
  Future<List<RemoteStockLevel>> fetchStockLevels() =>
      _lire('/stock-levels', RemoteStockLevel.fromJson);

  /// Les transferts qui attendent leur validation.
  Future<List<RemoteStockMovement>> fetchPendingTransfers() => _lire(
    '/stock-movements',
    RemoteStockMovement.fromJson,
    query: {'status_filter': 'PENDING'},
  );

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

    return _lire(
      '/reservations',
      RemoteReservation.fromJson,
      query: {'arrival_from': _jour(debut), 'arrival_to': _jour(fin)},
    );
  }

  /// Les sejours en cours, quelle que soit leur date d'arrivee.
  ///
  /// La fenetre de [fetchReservations] part de l'arrivee : un client
  /// installe depuis plus de 7 jours en sortait, et une tablette neuve ou
  /// reinstallee montrait sa chambre occupee sans personne dedans. Un depart
  /// oublie produisait le meme effet. Les sejours en cours sont peu
  /// nombreux : ils descendent tous.
  Future<List<RemoteReservation>> fetchStaysInHouse() => _lire(
    '/reservations',
    RemoteReservation.fromJson,
    query: {'status': 'CHECKED_IN'},
  );

  /// Les ardoises ouvertes, avec leurs lignes.
  ///
  /// Les ardoises closes ne descendent pas : elles ne bougent plus, et les
  /// rapatrier ferait grossir l'appel sans rien apporter a la reception.
  Future<List<RemoteFolio>> fetchOpenFolios() =>
      _lire('/folios', RemoteFolio.fromJson, query: {'status': 'OPEN'});

  /// Le parametrage de l'hotel (`HotelOut`), brut : nom, coordonnees et
  /// `logo_version`.
  Future<Map<String, dynamic>> fetchHotel() => _client.get('/hotel');

  /// Le fichier du logo.
  Future<Uint8List> fetchHotelLogo() => _client.getBytes('/hotel/logo');

  /// Remplace le logo ; rend le parametrage, avec la nouvelle version.
  Future<Map<String, dynamic>> putHotelLogo(Uint8List octets) {
    final png = octets.length > 3 && octets[0] == 0x89 && octets[1] == 0x50;
    return _client.putFile(
      '/hotel/logo',
      FormData.fromMap({
        'file': MultipartFile.fromBytes(
          octets,
          filename: png ? 'logo.png' : 'logo.jpg',
          contentType: DioMediaType('image', png ? 'png' : 'jpeg'),
        ),
      }),
    );
  }

  Future<void> deleteHotelLogo() => _client.delete('/hotel/logo');

  /// Les ardoises closes depuis `since`, pour les rapports seulement.
  ///
  /// Une vente au comptoir s'ouvre et se clot dans la meme requete : sans cet
  /// appel, les autres postes n'en verraient jamais le chiffre.
  Future<List<RemoteFolio>> fetchClosedFolios(DateTime since) => _lire(
    '/folios',
    RemoteFolio.fromJson,
    query: {'closed_since': _jour(since)},
  );

  /// Les encaissements depuis la journee hoteliere `since`.
  Future<List<RemotePayment>> fetchPayments(DateTime since) =>
      _lire('/payments', RemotePayment.fromJson, query: {'since': _jour(since)});

  /// Les caisses ouvertes depuis le jour `since`, plus celles encore
  /// ouvertes et les versements a confirmer. Celles de tout l'hotel pour la
  /// caisse centrale, les siennes pour un autre agent.
  Future<List<RemoteCashSession>> fetchCashSessions(DateTime since) => _lire(
    '/cash-sessions',
    RemoteCashSession.fromJson,
    query: {'since': _jour(since)},
  );

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