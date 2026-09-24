/// Descente des donnees du serveur vers la base locale.
///
/// Le sens **serveur -> tablette**. Le sens inverse, c'est la file
/// `outbox_entries` (voir `outbox.dart`), et son moteur n'existe pas encore.
///
/// Le principe qui gouverne tout : **les ecrans ne voient jamais passer ces
/// appels**. Ils lisent Drift, en flux continu ; quand cette classe ecrit, les
/// `watch()` se declenchent et l'interface se repeint toute seule. C'est ce
/// qui fait qu'un rafraichissement rate ne casse rien — l'ecran continue
/// d'afficher ce qu'il avait.
///
/// Ce n'est pas encore une synchronisation : pas de curseur, pas de delta, pas
/// de conflit. C'est un rafraichissement complet du referentiel, qui suffit
/// pour un parc de vingt chambres et qui donne a la tablette de vraies
/// donnees plutot qu'un jeu de demonstration.
library;

import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';
import '../remote/api_client.dart';
import '../remote/catalog_api.dart';

/// Ce qu'un rafraichissement a donne.
class SyncOutcome {
  const SyncOutcome.done(this.rooms) : offline = false, error = null;
  const SyncOutcome.offline() : rooms = 0, offline = true, error = null;
  const SyncOutcome.failed(this.error) : rooms = 0, offline = false;

  final int rooms;

  /// Serveur injoignable. **Pas une erreur** : l'etat normal d'une tablette
  /// dans un couloir. L'ecran garde ce qu'il affichait.
  final bool offline;

  final String? error;

  bool get succeeded => error == null && !offline;
}

class SyncRepository {
  const SyncRepository(this.db, this._catalog, {this.hotelId = _defaultHotel});

  final AtriumDatabase db;
  final CatalogApi _catalog;
  final String hotelId;

  static const _defaultHotel = '01920000-0000-7000-8000-000000000001';

  /// Rapatrie le parc de chambres et le recopie dans Drift.
  ///
  /// Les etages et les categories sont ecrits avant les chambres : la base
  /// locale a des cles etrangeres, et une chambre dont la categorie n'existe
  /// pas encore serait refusee.
  Future<SyncOutcome> pullRooms() async {
    final List<RemoteRoom> rooms;
    try {
      rooms = await _catalog.fetchRooms();
    } on ApiException catch (e) {
      return e.isOffline
          ? const SyncOutcome.offline()
          : SyncOutcome.failed(e.message);
    }

    final now = DateTime.now().toUtc();

    await db.transaction(() async {
      // Dedoublonne : vingt chambres partagent quatre categories et cinq
      // etages, inutile de reecrire cent fois les memes lignes.
      final floors = <String, RemoteRoom>{};
      final types = <String, RemoteRoom>{};
      for (final r in rooms) {
        if (r.floorId != null) floors[r.floorId!] = r;
        types[r.roomTypeId] = r;
      }

      for (final r in floors.values) {
        await db
            .into(db.floors)
            .insertOnConflictUpdate(
              FloorsCompanion.insert(
                id: r.floorId!,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                code: r.floorCode ?? r.floorId!,
                label: r.floorLabel ?? '',
                syncState: const Value(SyncState.synced),
              ),
            );
      }

      for (final r in types.values) {
        await db
            .into(db.roomTypes)
            .insertOnConflictUpdate(
              RoomTypesCompanion.insert(
                id: r.roomTypeId,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                code: r.roomTypeCode,
                label: r.roomTypeLabel,
                defaultRate: Value(r.roomTypeRate),
                syncState: const Value(SyncState.synced),
              ),
            );
      }

      for (final r in rooms) {
        await db
            .into(db.rooms)
            .insertOnConflictUpdate(
              RoomsCompanion.insert(
                id: r.id,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                number: r.number,
                roomTypeId: r.roomTypeId,
                floorId: Value(r.floorId),
                // Les trois axes arrivent separes du serveur et le restent
                // ici : c'est la decision n°1 du projet, et la pastille se
                // recalcule a l'affichage.
                occupancyStatus: Value(_occupancy(r.occupancyStatus)),
                housekeepingStatus: Value(_housekeeping(r.housekeepingStatus)),
                isOutOfOrder: Value(r.isOutOfOrder),
                // Ces lignes viennent du serveur : elles n'ont rien a
                // remonter.
                syncState: const Value(SyncState.synced),
              ),
            );
      }
    });

    return SyncOutcome.done(rooms.length);
  }

  /// Traduit un statut du serveur, en gardant la valeur par defaut la plus
  /// sure si le serveur en inventait une inconnue de cette version.
  OccupancyStatus _occupancy(String v) => OccupancyStatus.values.firstWhere(
    (e) => e.name == v,
    orElse: () => OccupancyStatus.VACANT,
  );

  HousekeepingStatus _housekeeping(String v) => HousekeepingStatus.values
      .firstWhere((e) => e.name == v, orElse: () => HousekeepingStatus.CLEAN);
}
