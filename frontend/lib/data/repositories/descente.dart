/// Faire redescendre les donnees metier du serveur (6.3).
///
/// Le referentiel des chambres descendait deja (`SyncRepository.pullRooms`).
/// Ici viennent les clients, les reservations et les ardoises -- sans quoi
/// une tablette neuve reste **aveugle** : ses donnees sont sur le serveur et
/// elle ne sait pas aller les chercher. C'est ce qui rendait brutale la
/// moindre reinitialisation.
///
/// Trois regles gouvernent ce fichier.
///
/// **L'ordre des dependances.** La base locale a de vraies cles etrangeres :
/// une reservation dont le client n'existe pas encore est refusee. On ecrit
/// donc clients, puis dossiers, puis lignes de sejour, puis ardoises, puis
/// leurs lignes.
///
/// **Rien n'ecrase une ecriture en attente.** `lignesEnAttente` est consultee
/// pour chaque table avant d'ecrire quoi que ce soit. Tant qu'une
/// modification n'est pas remontee, la version locale fait foi.
///
/// **Une ligne refusee n'arrete pas le lot.** Une reservation dont la
/// categorie de chambre est inconnue localement ne doit pas priver la
/// reception des quarante autres. On la saute et on continue.
library;

import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';
import '../remote/api_client.dart';
import '../remote/catalog_api.dart';
import 'sync_repository.dart';

/// Ce qu'une descente a rapatrie.
class PullReport {
  const PullReport({
    this.guests = 0,
    this.reservations = 0,
    this.stayLines = 0,
    this.folios = 0,
    this.items = 0,
    this.skipped = 0,
    this.offline = false,
    this.error,
  });

  const PullReport.offline() : this(offline: true);
  const PullReport.failed(String message) : this(error: message);

  final int guests;
  final int reservations;
  final int stayLines;
  final int folios;
  final int items;

  /// Lignes ecartees : protegees par une ecriture en attente, ou refusees par
  /// une cle etrangere manquante.
  final int skipped;

  final bool offline;
  final String? error;

  bool get succeeded => error == null && !offline;

  int get total => guests + reservations + stayLines + folios + items;

  @override
  String toString() =>
      'PullReport($guests clients, $reservations reservations, '
      '$stayLines sejours, $folios ardoises, $items lignes, '
      '$skipped ecartees)';
}

class Descente {
  Descente(this.db, this._catalog, this._sync, {this.hotelId = _hotelParDefaut});

  final AtriumDatabase db;
  final CatalogApi _catalog;
  final SyncRepository _sync;
  final String hotelId;

  static const _hotelParDefaut = '01920000-0000-7000-8000-000000000001';

  /// Rapatrie clients, reservations et ardoises ouvertes.
  ///
  /// Un seul rapport pour les trois : ce qui interesse l'appelant, c'est si
  /// la tablette a rattrape le serveur, pas le detail de chaque ressource.
  Future<PullReport> pull() async {
    try {
      final clients = await _catalog.fetchGuests();
      final dossiers = await _catalog.fetchReservations();
      final ardoises = await _catalog.fetchOpenFolios();

      var ecartees = 0;
      final maintenant = DateTime.now().toUtc();

      final nClients = await _ecrireClients(clients, maintenant, (n) {
        ecartees += n;
      });
      final (nDossiers, nLignes, ecartDossiers) = await _ecrireReservations(
        dossiers,
        maintenant,
      );
      ecartees += ecartDossiers;
      final (nArdoises, nItems, ecartArdoises) = await _ecrireArdoises(
        ardoises,
        maintenant,
      );
      ecartees += ecartArdoises;

      return PullReport(
        guests: nClients,
        reservations: nDossiers,
        stayLines: nLignes,
        folios: nArdoises,
        items: nItems,
        skipped: ecartees,
      );
    } on ApiException catch (e) {
      // Hors ligne n'est pas une erreur : c'est l'etat normal d'une tablette
      // dans un couloir, et l'ecran garde ce qu'il affichait.
      return e.isOffline
          ? const PullReport.offline()
          : PullReport.failed(e.message);
    }
  }

  // --- Les clients -----------------------------------------------------------

  Future<int> _ecrireClients(
    List<RemoteGuest> clients,
    DateTime maintenant,
    void Function(int) ecartees,
  ) async {
    final proteges = await _sync.lignesEnAttente(db.guests);
    var ecrits = 0;
    var sautes = 0;

    await db.transaction(() async {
      for (final c in clients) {
        if (proteges.contains(c.id)) {
          sautes++;
          continue;
        }
        await db
            .into(db.guests)
            .insertOnConflictUpdate(
              GuestsCompanion.insert(
                id: c.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                code: c.code,
                firstName: c.firstName,
                lastName: c.lastName,
                phone: Value(c.phone),
                email: Value(c.email),
                nationality: Value(c.nationality),
                idDocumentType: Value(_document(c.documentType)),
                idDocumentNumber: Value(c.documentNumber),
                isVip: Value(c.isVip),
                // Vient du serveur : rien a remonter.
                syncState: const Value(SyncState.synced),
              ),
            );
        ecrits++;
      }
    });

    ecartees(sautes);
    return ecrits;
  }

  // --- Les reservations ------------------------------------------------------

  Future<(int, int, int)> _ecrireReservations(
    List<RemoteReservation> dossiers,
    DateTime maintenant,
  ) async {
    final protegesDossiers = await _sync.lignesEnAttente(db.reservations);
    final protegesLignes = await _sync.lignesEnAttente(db.reservationRooms);

    // Les cles etrangeres connues d'avance : une reservation qui designe un
    // client ou une categorie absents serait refusee, et l'exception ferait
    // tomber toute la transaction avec elle.
    final clientsConnus = await _identifiants('guests');
    final typesConnus = await _identifiants('room_types');
    final chambresConnues = await _identifiants('rooms');

    var dossiersEcrits = 0;
    var lignesEcrites = 0;
    var sautes = 0;

    await db.transaction(() async {
      for (final r in dossiers) {
        if (protegesDossiers.contains(r.id) ||
            !clientsConnus.contains(r.guestId)) {
          sautes++;
          continue;
        }

        await db
            .into(db.reservations)
            .insertOnConflictUpdate(
              ReservationsCompanion.insert(
                id: r.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                reference: r.reference,
                guestId: r.guestId,
                status: Value(_reservationStatus(r.status)),
                arrivalDate: r.arrivalDate,
                departureDate: r.departureDate,
                adults: Value(r.adults),
                children: Value(r.children),
                syncState: const Value(SyncState.synced),
              ),
            );
        dossiersEcrits++;

        for (final l in r.rooms) {
          if (protegesLignes.contains(l.id) ||
              !typesConnus.contains(l.roomTypeId)) {
            sautes++;
            continue;
          }
          await db
              .into(db.reservationRooms)
              .insertOnConflictUpdate(
                ReservationRoomsCompanion.insert(
                  id: l.id,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  reservationId: r.id,
                  roomTypeId: l.roomTypeId,
                  // Une chambre inconnue localement devient nulle plutot que
                  // de faire refuser la ligne : mieux vaut un sejour sans
                  // chambre attribuee qu'un sejour invisible.
                  roomId: Value(
                    chambresConnues.contains(l.roomId) ? l.roomId : null,
                  ),
                  arrivalDate: l.arrivalDate,
                  departureDate: l.departureDate,
                  adults: Value(l.adults),
                  children: Value(l.children),
                  nightlyRate: Value(l.nightlyRate),
                  status: Value(_reservationStatus(l.status)),
                  checkedInAt: Value(l.checkedInAt),
                  checkedOutAt: Value(l.checkedOutAt),
                  syncState: const Value(SyncState.synced),
                ),
              );
          lignesEcrites++;
        }
      }
    });

    return (dossiersEcrits, lignesEcrites, sautes);
  }

  // --- Les ardoises ----------------------------------------------------------

  Future<(int, int, int)> _ecrireArdoises(
    List<RemoteFolio> ardoises,
    DateTime maintenant,
  ) async {
    final protegesArdoises = await _sync.lignesEnAttente(db.folios);
    final protegesLignes = await _sync.lignesEnAttente(db.folioItems);
    final sejoursConnus = await _identifiants('reservation_rooms');

    var ardoisesEcrites = 0;
    var itemsEcrits = 0;
    var sautes = 0;

    await db.transaction(() async {
      for (final f in ardoises) {
        if (protegesArdoises.contains(f.id)) {
          sautes++;
          continue;
        }

        await db
            .into(db.folios)
            .insertOnConflictUpdate(
              FoliosCompanion.insert(
                id: f.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                number: f.number,
                type: Value(_folioType(f.type)),
                status: Value(_folioStatus(f.status)),
                reservationRoomId: Value(
                  sejoursConnus.contains(f.stayLineId) ? f.stayLineId : null,
                ),
                guestId: Value(f.guestId),
                chargesTotal: Value(f.chargesTotal),
                paymentsTotal: Value(f.paymentsTotal),
                balance: Value(f.balance),
                openedAt: Value(f.openedAt),
                closedAt: Value(f.closedAt),
                syncState: const Value(SyncState.synced),
              ),
            );
        ardoisesEcrites++;

        for (final i in f.items) {
          if (protegesLignes.contains(i.id)) {
            sautes++;
            continue;
          }
          await db
              .into(db.folioItems)
              .insertOnConflictUpdate(
                FolioItemsCompanion.insert(
                  id: i.id,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  folioId: f.id,
                  category: _categorie(i.category),
                  label: i.label,
                  quantity: Value(i.quantity),
                  unitPrice: Value(i.unitPrice),
                  amount: Value(i.amount),
                  taxRate: Value(i.taxRate),
                  taxAmount: Value(i.taxAmount),
                  businessDate: i.businessDate,
                  isVoid: Value(i.isVoid),
                  syncState: const Value(SyncState.synced),
                ),
              );
          itemsEcrits++;
        }
      }
    });

    return (ardoisesEcrites, itemsEcrits, sautes);
  }

  // --- Outils ----------------------------------------------------------------

  /// Les identifiants deja presents dans une table.
  ///
  /// Consultes avant d'ecrire : SQLite refuse une cle etrangere manquante, et
  /// l'exception ferait tomber toute la transaction -- donc tout le lot, pour
  /// une seule ligne mal accrochee.
  Future<Set<String>> _identifiants(String table) async {
    final lignes = await db
        .customSelect('SELECT id AS id FROM $table WHERE deleted_at IS NULL')
        .get();
    return lignes.map((l) => l.read<String>('id')).toSet();
  }

  static ReservationStatus _reservationStatus(String v) =>
      ReservationStatus.values.firstWhere(
        (s) => s.name == v,
        orElse: () => ReservationStatus.PENDING,
      );

  static FolioStatus _folioStatus(String v) => FolioStatus.values.firstWhere(
    (s) => s.name == v,
    orElse: () => FolioStatus.OPEN,
  );

  static FolioType _folioType(String v) => FolioType.values.firstWhere(
    (s) => s.name == v,
    orElse: () => FolioType.GUEST,
  );

  static ChargeCategory _categorie(String v) =>
      ChargeCategory.values.firstWhere(
        (s) => s.name == v,
        orElse: () => ChargeCategory.MISC,
      );

  static IdDocumentType? _document(String? v) {
    if (v == null) return null;
    for (final t in IdDocumentType.values) {
      if (t.name == v) return t;
    }
    return null;
  }
}
