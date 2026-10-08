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

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import '../remote/api_client.dart';
import '../remote/catalog_api.dart';
import 'agent_repository.dart';
import 'settings_repository.dart' show depositRuleKey;
import 'sync_repository.dart';

/// Ce qu'une descente a rapatrie.
class PullReport {
  const PullReport({
    this.outlets = 0,
    this.menuCategories = 0,
    this.menuItems = 0,
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

  final int outlets;
  final int menuCategories;
  final int menuItems;
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

  int get total =>
      outlets +
      menuCategories +
      menuItems +
      guests +
      reservations +
      stayLines +
      folios +
      items;

  @override
  String toString() =>
      'PullReport($menuCategories categories de carte, $menuItems articles, '
      '$guests clients, $reservations reservations, '
      '$stayLines sejours, $folios ardoises, $items lignes, '
      '$skipped ecartees)';
}

class Descente {
  Descente(
    this.db,
    this._catalog,
    this._sync, {
    this.hotelId = _hotelParDefaut,
  });

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
      // Les points de vente d'abord : une commande s'y accroche, et un
      // point de vente absent ferait ecarter la ligne pour une raison qui
      // n'a rien a voir avec elle. La carte suit : categories, puis articles.
      //
      // Chaque ressource n'est lue que si l'agent en a le droit : la
      // reception ne lit pas le restaurant, le menage ne lit pas les
      // clients. Un refus (403) passait pour une panne et faisait echouer
      // toute la descente -- la reception ne recevait plus ni clients, ni
      // reservations, ni ardoises.
      final pointsDeVente = await _siPermis(_catalog.fetchOutlets);
      final categoriesCarte = await _siPermis(_catalog.fetchMenuCategories);
      final articlesCarte = await _siPermis(_catalog.fetchMenuItems);
      final clients = await _siPermis(_catalog.fetchGuests);
      final dossiers = await _siPermis(() => _catalog.fetchReservations());
      final ardoises = await _siPermis(_catalog.fetchOpenFolios);
      final regleArrhes = await _catalog.fetchDepositRule();
      final agents = await _siPermis(_catalog.fetchUsers);
      final roles = await _siPermis(_catalog.fetchRoles);
      final permissions = await _siPermis(_catalog.fetchPermissions);

      var ecartees = 0;
      final maintenant = DateTime.now().toUtc();

      final nPoints = await _ecrirePointsDeVente(pointsDeVente, maintenant);
      await _ecrireRegleArrhes(regleArrhes, maintenant);
      // Les agents : chacun avec ses roles, ses permissions et ses points de
      // vente. `applyServerAgent` epargne un agent modifie ici et pas encore
      // remonte.
      final depotAgents = AgentRepository(db, hotelId: hotelId);
      // Le catalogue d'abord, puis les roles qui s'y referent, puis les
      // agents qui portent ces roles.
      for (final p in permissions) {
        await depotAgents.applyServerPermission(p);
      }
      for (final r in roles) {
        await depotAgents.applyServerRole(r);
      }
      for (final a in agents) {
        await depotAgents.applyServerAgent(a);
      }
      final nCategories = await _ecrireCategoriesCarte(
        categoriesCarte,
        maintenant,
      );
      final nArticles = await _ecrireArticlesCarte(articlesCarte, maintenant);
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
        outlets: nPoints,
        menuCategories: nCategories,
        menuItems: nArticles,
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

  /// La ressource, ou rien si l'agent n'a pas le droit de la lire.
  ///
  /// Rien, c'est une liste vide : la descente n'efface jamais, une liste
  /// vide veut seulement dire « rien a ecrire ». Toute autre erreur remonte
  /// telle quelle -- hors ligne compris, que `pull` traite a part.
  Future<List<T>> _siPermis<T>(Future<List<T>> Function() lire) async {
    try {
      return await lire();
    } on ApiException catch (e) {
      if (e.failure == ApiFailure.forbidden) return <T>[];
      rethrow;
    }
  }

  // --- La regle des arrhes --------------------------------------------------

  /// Ecrit la regle des arrhes, sauf si l'administration de cette tablette en
  /// a fixe une qui n'est pas encore remontee.
  Future<void> _ecrireRegleArrhes(Object? regle, DateTime maintenant) async {
    final existante = await (db.select(db.settings)..where(
          (s) =>
              s.key.equals(depositRuleKey) &
              s.scope.equalsValue(SettingScope.GLOBAL) &
              s.scopeId.isNull(),
        ))
        .getSingleOrNull();
    if (existante?.syncState == SyncState.pending) return;

    await db
        .into(db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(
            id: existante?.id ?? newId(),
            createdAt: existante?.createdAt ?? maintenant,
            updatedAt: maintenant,
            hotelId: hotelId,
            key: depositRuleKey,
            value: Value(regle == null ? null : jsonEncode(regle)),
            label: const Value('Regle des arrhes'),
            syncState: const Value(SyncState.synced),
          ),
        );
  }

  // --- Les points de vente ---------------------------------------------------

  /// Ecrit les points de vente.
  ///
  /// L'ecran d'administration les modifie depuis la tablette : un point de
  /// vente en attente de remontee n'est pas ecrase, comme partout ailleurs.
  Future<int> _ecrirePointsDeVente(
    List<RemoteOutlet> points,
    DateTime maintenant,
  ) async {
    if (points.isEmpty) return 0;
    final proteges = await _sync.lignesEnAttente(db.outlets);

    await db.transaction(() async {
      for (final o in points) {
        if (proteges.contains(o.id)) continue;
        await db
            .into(db.outlets)
            .insertOnConflictUpdate(
              OutletsCompanion.insert(
                id: o.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                code: o.code,
                label: o.label,
                opensAt: Value(o.opensAt),
                closesAt: Value(o.closesAt),
                allowsRoomCharge: Value(o.allowsRoomCharge),
                sortOrder: Value(o.sortOrder),
                isActive: Value(o.isActive),
                syncState: const Value(SyncState.synced),
              ),
            );
      }
    });

    return points.length;
  }

  // --- La carte du restaurant ------------------------------------------------

  /// Ecrit les categories de la carte.
  ///
  /// Referentiel : pas de barriere d'ecritures en attente, le serveur fait foi.
  /// `outletId` nul = categorie commune a tous les points de vente. Aucune cle
  /// etrangere cote local : la valeur du serveur est stockee telle quelle.
  Future<int> _ecrireCategoriesCarte(
    List<RemoteMenuCategory> categories,
    DateTime maintenant,
  ) async {
    if (categories.isEmpty) return 0;

    await db.transaction(() async {
      for (final c in categories) {
        await db
            .into(db.menuCategories)
            .insertOnConflictUpdate(
              MenuCategoriesCompanion.insert(
                id: c.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                label: c.label,
                outletId: Value(c.outletId),
                sortOrder: Value(c.sortOrder),
                syncState: const Value(SyncState.synced),
              ),
            );
      }
    });

    return categories.length;
  }

  /// Ecrit les articles de la carte.
  ///
  /// `prepStationId` est stocke tel que le serveur l'envoie, meme si les
  /// postes de preparation ne descendent pas encore : c'est cette valeur qui
  /// portera le routage cuisine/bar. `taxRate` est un pourcentage (0 a 100),
  /// a garder tel quel.
  Future<int> _ecrireArticlesCarte(
    List<RemoteMenuItem> articles,
    DateTime maintenant,
  ) async {
    if (articles.isEmpty) return 0;

    await db.transaction(() async {
      for (final a in articles) {
        await db
            .into(db.menuItems)
            .insertOnConflictUpdate(
              MenuItemsCompanion.insert(
                id: a.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                code: a.code,
                label: a.label,
                menuCategoryId: a.menuCategoryId,
                prepStationId: Value(a.prepStationId),
                price: Value(a.price),
                taxRate: Value(a.taxRate),
                isAvailable: Value(a.isAvailable),
                syncState: const Value(SyncState.synced),
              ),
            );
      }
    });

    return articles.length;
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
                creditLimit: Value(c.creditLimit),
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
                // Les arrhes, pour que la liste des reservations les montre
                // aussi sur les tablettes ou le dossier n'a pas ete saisi.
                depositAmount: Value(r.depositAmount),
                depositPaidAt: Value(r.depositPaidAt),
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

  static ReservationStatus _reservationStatus(String v) => ReservationStatus
      .values
      .firstWhere((s) => s.name == v, orElse: () => ReservationStatus.PENDING);

  static FolioStatus _folioStatus(String v) => FolioStatus.values.firstWhere(
    (s) => s.name == v,
    orElse: () => FolioStatus.OPEN,
  );

  static FolioType _folioType(String v) => FolioType.values.firstWhere(
    (s) => s.name == v,
    orElse: () => FolioType.GUEST,
  );

  static ChargeCategory _categorie(String v) => ChargeCategory.values
      .firstWhere((s) => s.name == v, orElse: () => ChargeCategory.MISC);

  static IdDocumentType? _document(String? v) {
    if (v == null) return null;
    for (final t in IdDocumentType.values) {
      if (t.name == v) return t;
    }
    return null;
  }
}