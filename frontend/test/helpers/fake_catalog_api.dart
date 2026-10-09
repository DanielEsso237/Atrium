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
    this.folios = const [],
    this.outlets = const [],
    this.menuCategories = const [],
    this.menuItems = const [],
    this.depositRule,
    this.users = const [],
    this.roles = const [],
    this.permissions = const [],
    this.products = const [],
    this.stockLocations = const [],
    this.stockLevels = const [],
    this.pendingTransfers = const [],
    this.hotel,
    this.logo,
  });

  final List<RemoteRoom> rooms;
  final List<RemoteGuest> guests;
  final List<RemoteReservation> reservations;
  final List<RemoteFolio> folios;
  final List<RemoteOutlet> outlets;
  final List<RemoteMenuCategory> menuCategories;
  final List<RemoteMenuItem> menuItems;
  final Object? depositRule;
  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> roles;
  final List<Map<String, dynamic>> permissions;
  final List<RemoteProduct> products;
  final List<RemoteStockLocation> stockLocations;
  final List<RemoteStockLevel> stockLevels;
  final List<RemoteStockMovement> pendingTransfers;

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
  Future<List<RemoteOutlet>> fetchOutlets() async => outlets;

  @override
  Future<List<RemoteMenuCategory>> fetchMenuCategories() async =>
      menuCategories;

  @override
  Future<List<RemoteMenuItem>> fetchMenuItems() async => menuItems;

  @override
  Future<Object?> fetchDepositRule() async => depositRule;

  @override
  Future<List<Map<String, dynamic>>> fetchUsers() async => users;

  @override
  Future<List<Map<String, dynamic>>> fetchRoles() async => roles;

  @override
  Future<List<Map<String, dynamic>>> fetchPermissions() async => permissions;
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
  Future<List<RemoteOutlet>> fetchOutlets() async => _couloir();

  @override
  Future<List<RemoteMenuCategory>> fetchMenuCategories() async => _couloir();

  @override
  Future<List<RemoteMenuItem>> fetchMenuItems() async => _couloir();

  @override
  Future<Object?> fetchDepositRule() async => _couloir();

  @override
  Future<List<Map<String, dynamic>>> fetchUsers() async => _couloir();

  @override
  Future<List<Map<String, dynamic>>> fetchRoles() async => _couloir();

  @override
  Future<List<Map<String, dynamic>>> fetchPermissions() async => _couloir();
}