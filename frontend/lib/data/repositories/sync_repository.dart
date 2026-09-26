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

      // Les chambres dont une ecriture locale attend de remonter ne sont PAS
      // ecrasees. Sans cette regle, un check-in fait hors ligne disparait au
      // premier rapatriement : le serveur ignore tout de lui, il renvoie la
      // chambre libre, et l'agent voit son client s'evaporer du plan.
      //
      // La regle generale : tant qu'une modification n'est pas remontee, la
      // version locale fait foi. C'est le serveur qui est en retard, pas la
      // tablette.
      final enAttente = await _roomsWithPendingWrites();

      for (final r in rooms) {
        if (enAttente.contains(r.id)) continue;

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

  /// Les chambres qu'une ecriture locale protege de l'ecrasement.
  ///
  /// Deux sources, parce qu'elles ne disent pas la meme chose :
  ///
  /// - `syncState = pending` sur la chambre elle-meme : elle a ete modifiee
  ///   ici et n'est pas remontee ;
  /// - la file d'attente : un check-in modifie la LIGNE DE SEJOUR, pas
  ///   directement la chambre, mais il change son occupation. Sans regarder
  ///   la file, on ecraserait quand meme.
  /// Les lignes d'une table qu'une descente ne doit pas ecraser.
  ///
  /// **C'est la barriere qui protege le travail d'un agent.** Tant qu'une
  /// modification n'est pas remontee, la version locale fait foi : c'est le
  /// serveur qui est en retard, pas la tablette. L'ecraser ferait disparaitre
  /// un check-in ou une reservation que quelqu'un vient de saisir, sans trace
  /// et sans avertissement.
  ///
  /// Deux sources, et il faut les deux :
  ///
  /// - la ligne elle-meme marquee `pending` ;
  /// - la ligne **nommee par une entree de la file** encore non acquittee.
  ///   Une entree `FAILED` compte autant qu'une `PENDING` : elle sera
  ///   rejouee, donc son intention tient toujours.
  ///
  /// Publique parce qu'elle se teste : une barriere de securite qu'on ne peut
  /// pas verifier n'en est pas une. Le nom de table vient de Drift, jamais
  /// d'une donnee.
  Future<Set<String>> lignesEnAttente(TableInfo table) async {
    final nom = table.actualTableName;

    final lignes = await db
        .customSelect(
          """
      SELECT id AS id FROM $nom WHERE sync_state = 'pending'
      UNION
      SELECT entity_id AS id FROM outbox_entries
       WHERE entity_table = ?1
         AND status IN ('PENDING','FAILED')
      """,
          variables: [Variable.withString(nom)],
          readsFrom: {table, db.outboxEntries},
        )
        .get();

    return lignes.map((l) => l.read<String>('id')).toSet();
  }

  /// Les chambres a epargner.
  ///
  /// La regle generale, plus une regle propre aux chambres : une chambre est
  /// aussi protegee par une ecriture en attente sur une **autre** table. Un
  /// check-in pas encore remonte vit dans `reservation_rooms`, et c'est
  /// pourtant l'occupation de la chambre qu'il change. Sans cette jointure,
  /// la descente rendait libre une chambre ou quelqu'un venait d'entrer --
  /// c'est le bug de la chambre 202.
  Future<Set<String>> _roomsWithPendingWrites() async {
    final directes = await lignesEnAttente(db.rooms);

    final indirectes = await db
        .customSelect(
          """
      SELECT rr.room_id AS id
        FROM outbox_entries o
        JOIN reservation_rooms rr ON rr.id = o.entity_id
       WHERE o.entity_table = 'reservation_rooms'
         AND o.status IN ('PENDING','FAILED')
         AND rr.room_id IS NOT NULL
      """,
          readsFrom: {db.outboxEntries, db.reservationRooms},
        )
        .get();

    return {...directes, ...indirectes.map((l) => l.read<String>('id'))};
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
