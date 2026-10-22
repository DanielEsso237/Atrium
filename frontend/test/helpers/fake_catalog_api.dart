/// Un `CatalogApi` de test : rend ce qu'on lui donne, sans reseau.
///
/// Partage entre tous les tests de descente. Le premier faux vivait dans un
/// seul fichier de test et `implements CatalogApi` : ajouter une methode au
/// vrai client cassait ce test-la, pour une raison sans rapport avec ce qu'il
/// verifiait. Un seul endroit a mettre a jour vaut mieux qu'un piege pose sous
/// les pas du suivant.
library;

import 'dart:typed_data';

import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/catalog_api.dart';

class FakeCatalogApi implements CatalogApi {
  const FakeCatalogApi({
    this.rooms = const [],
    this.guests = const [],
    this.reservations = const [],
    this.staysInHouse,
    this.folios = const [],
    this.outlets = const [],
    this.menuCategories = const [],
    this.menuItems = const [],
    this.depositRule,
    this.notificationLevels,
    this.users = const [],
    this.roles = const [],
    this.permissions = const [],
    this.empreintes = const [],
    this.products = const [],
    this.stockLocations = const [],
    this.stockLevels = const [],
    this.pendingTransfers = const [],
    this.hotel,
    this.logo,
    this.closedFolios = const [],
    this.payments = const [],
    this.cashSessions = const [],
    this.outletActivity = const RemoteOutletActivity(),
    this.chargeableStays = const [],
    this.inventories,
    this.roomOrders,
  });

  final List<RemoteRoom> rooms;
  final List<RemoteGuest> guests;
  final List<RemoteReservation> reservations;

  /// Les sejours en cours rendus a part ; par defaut, ceux de
  /// [reservations] qui sont CHECKED_IN, comme le serveur.
  final List<RemoteReservation>? staysInHouse;
  final List<RemoteFolio> folios;
  final List<RemoteOutlet> outlets;
  final List<RemoteMenuCategory> menuCategories;
  final List<RemoteMenuItem> menuItems;
  final Object? depositRule;
  final Object? notificationLevels;
  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> roles;
  final List<Map<String, dynamic>> permissions;

  /// `GET /auth/credentials` : les agents avec leurs empreintes.
  final List<Map<String, dynamic>> empreintes;
  final List<RemoteProduct> products;
  final List<RemoteStockLocation> stockLocations;
  final List<RemoteStockLevel> stockLevels;
  final List<RemoteStockMovement> pendingTransfers;
  final List<RemoteFolio> closedFolios;
  final List<RemotePayment> payments;
  final List<RemoteCashSession> cashSessions;
  final RemoteOutletActivity outletActivity;
  final List<RemoteChargeableStay> chargeableStays;

  /// `null` : un serveur sans la route des inventaires.
  final List<RemoteInventory>? inventories;

  /// `null` : un serveur sans la route des commandes en chambre.
  final List<RemoteRoomOrder>? roomOrders;

  /// `HotelOut` brut ; `null` : le serveur ne l'expose pas (ancien serveur).
  final Map<String, dynamic>? hotel;
  final Uint8List? logo;

  @override
  Future<List<RemoteRoom>> fetchRooms() async => rooms;

  @override
  Future<List<RemoteProduct>> fetchProducts() async => products;

  @override
  Future<List<RemoteStockLocation>> fetchStockLocations() async =>
      stockLocations;

  @override
  Future<List<RemoteStockLevel>> fetchStockLevels() async => stockLevels;

  @override
  Future<List<RemoteStockMovement>> fetchPendingTransfers() async =>
      pendingTransfers;

  @override
  Future<List<RemoteGuest>> fetchGuests() async => guests;

  @override
  Future<List<RemoteReservation>> fetchReservations({
    DateTime? from,
    DateTime? to,
    int joursAvant = 7,
    int joursApres = 30,
  }) async => reservations;

  @override
  Future<List<RemoteReservation>> fetchStaysInHouse() async =>
      staysInHouse ??
      reservations.where((r) => r.status == 'CHECKED_IN').toList();

  @override
  Future<List<RemoteFolio>> fetchOpenFolios() async => folios;

  @override
  Future<Map<String, dynamic>> fetchHotel() async =>
      hotel ?? (throw const ApiException(ApiFailure.notFound, 'absent'));

  @override
  Future<Uint8List> fetchHotelLogo() async =>
      logo ?? (throw const ApiException(ApiFailure.notFound, 'absent'));

  @override
  Future<Map<String, dynamic>> putHotelLogo(Uint8List octets) async => {
    ...?hotel,
    'logo_version': 'srv-${octets.length}',
  };

  @override
  Future<void> deleteHotelLogo() async {}

  @override
  Future<List<RemoteFolio>> fetchClosedFolios(DateTime since) async =>
      closedFolios;

  @override
  Future<List<RemotePayment>> fetchPayments(DateTime since) async => payments;

  @override
  Future<List<RemoteCashSession>> fetchCashSessions(DateTime since) async =>
      cashSessions;

  @override
  Future<RemoteOutletActivity> fetchOutletActivity(DateTime since) async =>
      outletActivity;

  @override
  Future<List<RemoteChargeableStay>> fetchChargeableStays() async =>
      chargeableStays;

  @override
  Future<List<RemoteOutlet>> fetchOutlets() async => outlets;

  @override
  Future<List<RemoteMenuCategory>> fetchMenuCategories() async =>
      menuCategories;

  @override
  Future<List<RemoteMenuItem>> fetchMenuItems() async => menuItems;

  @override
  Future<Object?> fetchDepositRule() async => depositRule;

  @override
  Future<Object?> fetchNotificationLevels() async => notificationLevels;

  /// `null` : le serveur n'a jamais regle les sonneries de l'hotel.
  @override
  Future<Object?> fetchNotificationSounds() async => null;

  @override
  Future<List<RemoteExpense>> fetchExpenses(DateTime since) async => const [];

  @override
  Future<List<RemoteInventory>?> fetchInventories(DateTime since) async =>
      inventories;

  @override
  Future<List<RemoteRoomOrder>?> fetchRoomOrders(DateTime since) async =>
      roomOrders;

  /// `null` : un serveur sans la route des couts, la tablette garde les siens.
  @override
  Future<List<RemoteDailyCost>?> fetchDailyCosts(DateTime since) async => null;

  @override
  Future<List<Map<String, dynamic>>> fetchUsers() async => users;

  @override
  Future<List<Map<String, dynamic>>> fetchRoles() async => roles;

  @override
  Future<List<Map<String, dynamic>>> fetchPermissions() async => permissions;

  @override
  Future<List<Map<String, dynamic>>> fetchCredentials() async => empreintes;
}

/// Un serveur injoignable : tout appel echoue comme dans un couloir.
///
/// Dans le meme fichier que `FakeCatalogApi`, et pour la meme raison :
/// ajouter une methode au vrai client cassait les deux, chacun dans son coin.
class CatalogApiHorsLigne implements CatalogApi {
  const CatalogApiHorsLigne();

  Never _couloir() =>
      throw const ApiException(ApiFailure.offline, 'injoignable');

  @override
  Future<List<RemoteRoom>> fetchRooms() async => _couloir();

  @override
  Future<List<RemoteProduct>> fetchProducts() async => _couloir();

  @override
  Future<List<RemoteStockLocation>> fetchStockLocations() async => _couloir();

  @override
  Future<List<RemoteStockLevel>> fetchStockLevels() async => _couloir();

  @override
  Future<List<RemoteStockMovement>> fetchPendingTransfers() async =>
      _couloir();

  @override
  Future<List<RemoteGuest>> fetchGuests() async => _couloir();

  @override
  Future<List<RemoteReservation>> fetchReservations({
    DateTime? from,
    DateTime? to,
    int joursAvant = 7,
    int joursApres = 30,
  }) async => _couloir();

  @override
  Future<List<RemoteReservation>> fetchStaysInHouse() async => _couloir();

  @override
  Future<List<RemoteFolio>> fetchOpenFolios() async => _couloir();

  @override
  Future<Map<String, dynamic>> fetchHotel() async => _couloir();

  @override
  Future<Uint8List> fetchHotelLogo() async => _couloir();

  @override
  Future<Map<String, dynamic>> putHotelLogo(Uint8List octets) async =>
      _couloir();

  @override
  Future<void> deleteHotelLogo() async => _couloir();

  @override
  Future<List<RemoteFolio>> fetchClosedFolios(DateTime since) async =>
      _couloir();

  @override
  Future<List<RemotePayment>> fetchPayments(DateTime since) async =>
      _couloir();

  @override
  Future<List<RemoteCashSession>> fetchCashSessions(DateTime since) async =>
      _couloir();

  @override
  Future<RemoteOutletActivity> fetchOutletActivity(DateTime since) async =>
      _couloir();

  @override
  Future<List<RemoteChargeableStay>> fetchChargeableStays() async =>
      _couloir();

  @override
  Future<List<RemoteOutlet>> fetchOutlets() async => _couloir();

  @override
  Future<List<RemoteMenuCategory>> fetchMenuCategories() async => _couloir();

  @override
  Future<List<RemoteMenuItem>> fetchMenuItems() async => _couloir();

  @override
  Future<Object?> fetchDepositRule() async => _couloir();

  @override
  Future<Object?> fetchNotificationLevels() async => _couloir();

  @override
  Future<Object?> fetchNotificationSounds() async => _couloir();

  @override
  Future<List<RemoteExpense>> fetchExpenses(DateTime since) async => _couloir();

  @override
  Future<List<RemoteInventory>?> fetchInventories(DateTime since) async =>
      _couloir();

  @override
  Future<List<RemoteRoomOrder>?> fetchRoomOrders(DateTime since) async =>
      _couloir();

  @override
  Future<List<RemoteDailyCost>?> fetchDailyCosts(DateTime since) async =>
      _couloir();

  @override
  Future<List<Map<String, dynamic>>> fetchUsers() async => _couloir();

  @override
  Future<List<Map<String, dynamic>>> fetchRoles() async => _couloir();

  @override
  Future<List<Map<String, dynamic>>> fetchPermissions() async => _couloir();

  @override
  Future<List<Map<String, dynamic>>> fetchCredentials() async => _couloir();
}