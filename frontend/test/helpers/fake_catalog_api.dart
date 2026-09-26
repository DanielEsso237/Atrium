/// Un `CatalogApi` de test : rend ce qu'on lui donne, sans reseau.
///
/// Partage entre tous les tests de descente. Le premier faux vivait dans un
/// seul fichier de test et `implements CatalogApi` : ajouter une methode au
/// vrai client cassait ce test-la, pour une raison sans rapport avec ce qu'il
/// verifiait. Un seul endroit a mettre a jour vaut mieux qu'un piege pose sous
/// les pas du suivant.
library;

import 'package:atrium/data/remote/catalog_api.dart';

class FakeCatalogApi implements CatalogApi {
  const FakeCatalogApi({
    this.rooms = const [],
    this.guests = const [],
    this.reservations = const [],
    this.folios = const [],
  });

  final List<RemoteRoom> rooms;
  final List<RemoteGuest> guests;
  final List<RemoteReservation> reservations;
  final List<RemoteFolio> folios;

  @override
  Future<List<RemoteRoom>> fetchRooms() async => rooms;

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
}
