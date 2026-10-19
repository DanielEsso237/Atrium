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
import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/business_day.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import '../remote/api_client.dart';
import '../remote/catalog_api.dart';
import 'agent_repository.dart';
import 'cash_repository.dart';
import 'guest_repository.dart' show codeFromId;
import 'hotel_repository.dart';
import 'room_order_repository.dart';
import 'settings_repository.dart'
    show depositRuleKey, notificationLevelsKey, notificationSoundsKey;
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
      // L'hotel d'abord : son logo importe ici remonte avant que la
      // descente ne compare les versions, et son nom en tete des factures
      // suit le dernier enregistre. Un serveur qui ne l'expose pas encore
      // (404) n'empeche rien.
      try {
        await HotelRepository(db, hotelId: hotelId).synchroniser(_catalog);
      } on ApiException catch (e) {
        if (e.isOffline) rethrow;
        debugPrint('[Descente] hotel ecarte : ${e.message}');
      }
      final pointsDeVente = await _siPermis(_catalog.fetchOutlets);
      final categoriesCarte = await _siPermis(_catalog.fetchMenuCategories);
      final articlesCarte = await _siPermis(_catalog.fetchMenuItems);
      // Les stocks : reserves a qui porte stock.read.
      final produits = await _siPermis(_catalog.fetchProducts);
      final magasins = await _siPermis(_catalog.fetchStockLocations);
      final niveaux = await _siPermis(_catalog.fetchStockLevels);
      // `null` et non vide quand l'agent n'a pas le droit : une liste vide
      // ferait retirer de la tablette tous les transferts a valider.
      final transferts = await _siPermisOuRien(_catalog.fetchPendingTransfers);
      final clients = await _siPermis(_catalog.fetchGuests);
      // La fenetre des arrivees, plus tous les sejours en cours : un client
      // arrive avant la fenetre est encore dans sa chambre. Le meme dossier
      // peut venir des deux appels ; il ne s'ecrit qu'une fois.
      final enCours = await _siPermisOuRien(_catalog.fetchStaysInHouse);
      final dossiers = {
        for (final d in [
          ...await _siPermis(() => _catalog.fetchReservations()),
          ...?enCours,
        ])
          d.id: d,
      }.values.toList();
      final ardoises = await _siPermis(_catalog.fetchOpenFolios);
      // Qui ne lit pas les reservations -- le comptoir -- recoit a la place
      // les chambres a qui il peut porter. `null` : rien a faire, ni a
      // retirer (la reception lit deja tout, ou l'agent ne porte pas).
      final aPorter = enCours == null ? await _sejoursAPorter() : null;
      // Les rapports : ventes closes ailleurs et encaissements de tous les
      // postes, sur une fenetre glissante.
      final depuis = _debutFenetreRapports();
      final ardoisesCloses = await _siPermis(
        () => _catalog.fetchClosedFolios(depuis),
      );
      final encaissements = await _siPermis(
        () => _catalog.fetchPayments(depuis),
      );
      // Les depenses, pour le benefice : sous `accounting.read`, un 403
      // pour le comptoir, qui saute la ressource.
      final depenses = await _siPermis(() => _catalog.fetchExpenses(depuis));
      // Les inventaires des magasins : un second poste reprend celui qu'un
      // collegue a ouvert, au lieu d'en ouvrir un autre. Sous `stock.read`.
      final inventaires = await _siPermisOuRien<RemoteInventory>(
        () async =>
            await _catalog.fetchInventories(depuis) ??
            const <RemoteInventory>[],
      );
      // Les commandes en chambre (F2.6) : la reception suit celles qu'elle a
      // passees, le point de vente voit arriver celles qu'il doit monter.
      // Sous `order.read` ; `null` aussi si le serveur ne connait pas la route.
      final commandesChambre = await _siPermisOuRien<RemoteRoomOrder>(
        () async =>
            await _catalog.fetchRoomOrders(depuis) ?? const <RemoteRoomOrder>[],
      );
      // Et ce que chaque journee a coute en stock : les mouvements, eux, ne
      // descendent pas. Un 403 vaut « rien a ecrire », comme un 404.
      List<RemoteDailyCost>? couts;
      try {
        couts = await _catalog.fetchDailyCosts(depuis);
      } on ApiException catch (e) {
        if (e.failure != ApiFailure.forbidden) rethrow;
      }
      // Les caisses : celles de tout l'hotel pour la caisse centrale, qui y
      // lit ce que chaque point de vente lui doit ; les siennes pour un
      // autre agent, qui y voit son versement confirme.
      final caisses = await _siPermis(
        () => _catalog.fetchCashSessions(depuis),
      );
      // L'activite des points de vente de l'agent, sur tous les postes. Pour
      // qui lit deja ardoises et encaissements, elle redit une partie de ce
      // qui precede ; pour l'agent d'un point de vente, c'est la seule source
      // de son tableau de bord -- il ne lit ni `/folios` ni `/payments`.
      final activite = await _activitePointsDeVente(depuis);
      final regleArrhes = await _catalog.fetchDepositRule();
      final niveauxAlertes = await _catalog.fetchNotificationLevels();
      final sonneriesAlertes = await _catalog.fetchNotificationSounds();
      final agents = await _siPermis(_catalog.fetchUsers);
      final roles = await _siPermis(_catalog.fetchRoles);
      final permissions = await _siPermis(_catalog.fetchPermissions);

      var ecartees = 0;
      final maintenant = DateTime.now().toUtc();

      final nPoints = await _ecrirePointsDeVente(pointsDeVente, maintenant);
      await _ecrireRegleArrhes(regleArrhes, maintenant);
      await _ecrireReglageAlertes(
        notificationLevelsKey,
        'Niveaux des alertes',
        niveauxAlertes,
        maintenant,
      );
      await _ecrireReglageAlertes(
        notificationSoundsKey,
        'Sonneries des alertes',
        sonneriesAlertes,
        maintenant,
      );
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
      await _ecrireStocks(produits, magasins, niveaux, transferts, maintenant);
      final nClients = await _ecrireClients(clients, maintenant, (n) {
        ecartees += n;
      });
      final (nDossiers, nLignes, ecartDossiers) = await _ecrireReservations(
        dossiers,
        maintenant,
      );
      ecartees += ecartDossiers;
      // Avant les ardoises : une ardoise ne s'accroche qu'a un sejour connu.
      if (aPorter != null) {
        ecartees += await _ecrireSejoursAPorter(aPorter, maintenant);
      }
      final (nArdoises, nItems, ecartArdoises) = await _ecrireArdoises(
        [
          ...ardoises,
          ...ardoisesCloses,
          ...?aPorter?.map((s) => s.folio),
          // Les ardoises du comptoir : le barman ne lit pas `/folios`, elles
          // lui arrivent avec l'activite de ses points de vente.
          ...activite.tabs,
        ],
        maintenant,
      );
      ecartees += ecartArdoises;
      // Apres les ardoises completes : l'en-tete partiel d'une vente ne
      // s'ecrit que si l'ardoise manque.
      final (nVentes, ecartVentes) = await _ecrireVentesPointsDeVente(
        activite.sales,
        maintenant,
      );
      ecartees += ecartVentes;
      // Un meme encaissement ou une meme caisse peut venir des deux appels :
      // ecrits une fois.
      ecartees += await _ecrireEncaissements(
        {
          for (final p in [...encaissements, ...activite.payments]) p.id: p,
        }.values.toList(),
        maintenant,
      );
      ecartees += await _ecrireDepenses(depenses, maintenant);
      if (inventaires != null) {
        ecartees += await _ecrireInventaires(inventaires, maintenant);
      }
      if (commandesChambre != null) {
        ecartees += await _ecrireCommandesEnChambre(
          commandesChambre,
          maintenant,
        );
      }
      if (couts != null) await _ecrireCouts(couts, depuis, maintenant);
      ecartees += await _ecrireCaisses(
        {
          for (final c in [...caisses, ...activite.cashSessions]) c.id: c,
        }.values.toList(),
        maintenant,
      );

      return PullReport(
        outlets: nPoints,
        menuCategories: nCategories,
        menuItems: nArticles,
        guests: nClients,
        reservations: nDossiers,
        stayLines: nLignes,
        folios: nArdoises,
        items: nItems + nVentes,
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

  /// Comme [_siPermis], mais `null` sur un refus : pour les ressources dont
  /// l'absence sur le serveur fait retirer quelque chose de la tablette.
  Future<List<T>?> _siPermisOuRien<T>(Future<List<T>> Function() lire) async {
    try {
      return await lire();
    } on ApiException catch (e) {
      if (e.failure == ApiFailure.forbidden) return null;
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

  // --- Les niveaux et les sonneries des alertes -----------------------------

  /// Ecrit les niveaux ou les sonneries des alertes, sauf si l'administration
  /// de cette tablette les a changes et qu'ils ne sont pas encore remontes.
  /// `null` (serveur sans la route) ou vide (rien de fixe) : la tablette
  /// garde les siens.
  Future<void> _ecrireReglageAlertes(
    String cle,
    String libelle,
    Object? valeur,
    DateTime maintenant,
  ) async {
    if (valeur is! Map || valeur.isEmpty) return;
    final existante =
        await (db.select(db.settings)..where(
              (s) =>
                  s.key.equals(cle) &
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
            key: cle,
            value: Value(jsonEncode(valeur)),
            label: Value(libelle),
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
                kind: Value(
                  o.kind == 'SERVICE' ? OutletKind.SERVICE : OutletKind.OUTLET,
                ),
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
                productId: Value(a.productId),
                stockQuantity: Value(a.stockQuantity),
                syncState: const Value(SyncState.synced),
              ),
            );
      }
    });

    return articles.length;
  }

  // --- Les stocks ------------------------------------------------------------

  /// Ecrit produits, magasins, quantites et transferts a valider.
  ///
  /// **Une quantite ne doit pas effacer ce que la tablette a fait sans
  /// l'avoir encore envoye.** Le serveur ne connait ni la biere vendue hors
  /// ligne il y a dix minutes, ni l'entree saisie a l'economat pendant la
  /// coupure. La quantite ecrite est donc celle du serveur, plus l'effet des
  /// mouvements locaux pas encore remontes ([_enAttenteDeRemontee]).
  Future<void> _ecrireStocks(
    List<RemoteProduct> produits,
    List<RemoteStockLocation> magasins,
    List<RemoteStockLevel> niveaux,
    List<RemoteStockMovement>? transferts,
    DateTime maintenant,
  ) async {
    final protegesMouvements = await _sync.lignesEnAttente(db.stockMovements);
    final enAttente = await _enAttenteDeRemontee();

    await db.transaction(() async {
      for (final p in produits) {
        await db
            .into(db.products)
            .insertOnConflictUpdate(
              ProductsCompanion.insert(
                id: p.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                reference: p.reference,
                label: p.label,
                categoryId: Value(p.categoryId),
                unit: Value(p.unit),
                purchasePrice: Value(p.purchasePrice),
                salePrice: Value(p.salePrice),
                averageCost: Value(p.averageCost),
                minStock: Value(p.minStock),
                syncState: const Value(SyncState.synced),
              ),
            );
      }

      for (final m in magasins) {
        await db
            .into(db.stockLocations)
            .insertOnConflictUpdate(
              StockLocationsCompanion.insert(
                id: m.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                code: m.code,
                label: m.label,
                sortOrder: Value(m.sortOrder),
                outletId: Value(m.outletId),
                isCentral: Value(m.isCentral),
                syncState: const Value(SyncState.synced),
              ),
            );
      }

      for (final n in niveaux) {
        final cle = '${n.productId}|${n.locationId}';
        final quantite = n.quantity + (enAttente[cle] ?? 0);
        final existant =
            await (db.select(db.stockLevels)..where(
                  (l) =>
                      l.productId.equals(n.productId) &
                      l.stockLocationId.equals(n.locationId),
                ))
                .getSingleOrNull();
        if (existant == null) {
          await db
              .into(db.stockLevels)
              .insert(
                StockLevelsCompanion.insert(
                  id: newId(),
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  productId: n.productId,
                  stockLocationId: n.locationId,
                  quantity: Value(quantite),
                  lastMovementAt: Value(n.lastMovementAt),
                  syncState: const Value(SyncState.synced),
                ),
              );
        } else {
          await (db.update(
            db.stockLevels,
          )..where((l) => l.id.equals(existant.id))).write(
            StockLevelsCompanion(
              quantity: Value(quantite),
              lastMovementAt: Value(n.lastMovementAt),
              updatedAt: Value(maintenant),
            ),
          );
        }
      }

      if (transferts == null) return;
      final surLeServeur = <String>{};
      for (final t in transferts) {
        surLeServeur.add(t.id);
        // Une decision prise ici et pas encore remontee fait foi.
        if (protegesMouvements.contains(t.id)) continue;
        await db
            .into(db.stockMovements)
            .insertOnConflictUpdate(
              StockMovementsCompanion.insert(
                id: t.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                productId: t.productId,
                stockLocationId: t.locationId,
                type: StockMovementType.values.firstWhere(
                  (v) => v.name == t.type,
                  orElse: () => StockMovementType.TRANSFER,
                ),
                quantity: t.quantity,
                counterpartLocationId: Value(t.counterpartLocationId),
                reason: Value(t.reason),
                movedAt: Value(t.movedAt),
                movedBy: Value(t.movedBy),
                status: const Value(StockMovementStatus.PENDING),
                syncState: const Value(SyncState.synced),
              ),
            );
      }
      // Un transfert qui n'attend plus sur le serveur a ete valide ou refuse
      // sur un autre poste : il quitte la liste « a valider » d'ici. Seuls
      // ceux venus du serveur ; une demande faite ici et pas encore remontee
      // reste.
      final perimes =
          await (db.select(db.stockMovements)..where(
                (m) =>
                    m.status.equalsValue(StockMovementStatus.PENDING) &
                    m.syncState.equalsValue(SyncState.synced),
              ))
              .get();
      for (final m in perimes) {
        if (surLeServeur.contains(m.id)) continue;
        await (db.delete(
          db.stockMovements,
        )..where((x) => x.id.equals(m.id))).go();
      }
    });
  }

  /// L'effet sur chaque stock (« produit|magasin ») des mouvements que le
  /// serveur ne connait pas encore.
  ///
  /// Deux sortes : ceux que la tablette a saisis et qui attendent dans la
  /// file (`pending`), et les sorties de vente, qui ne remontent pas elles-
  /// memes mais avec leur ligne d'ardoise -- tant que celle-ci attend, le
  /// serveur n'a rien fait sortir. Un transfert ne compte qu'une fois valide.
  Future<Map<String, int>> _enAttenteDeRemontee() async {
    final lignes = await db
        .customSelect(
          """
      SELECT m.product_id, m.stock_location_id, m.counterpart_location_id,
             m.type, m.quantity
        FROM stock_movements m
       WHERE m.deleted_at IS NULL
         AND m.status = 'APPROVED'
         AND (m.sync_state = 'pending'
              OR (m.source_table = 'folio_items'
                  AND m.source_id IN (
                        SELECT fi.id FROM folio_items fi
                         WHERE fi.sync_state = 'pending'
                            -- Une vente de passage remonte avec son ardoise,
                            -- pas ligne par ligne.
                            OR fi.folio_id IN (
                                 SELECT f.id FROM folios f
                                  WHERE f.type = 'WALK_IN'
                                    AND f.sync_state = 'pending'))))
      """,
          readsFrom: {db.stockMovements, db.folioItems, db.folios},
        )
        .get();

    final effet = <String, int>{};
    void ajouter(String produit, String? magasin, int delta) {
      if (magasin == null) return;
      final cle = '$produit|$magasin';
      effet[cle] = (effet[cle] ?? 0) + delta;
    }

    for (final l in lignes) {
      final produit = l.read<String>('product_id');
      final magasin = l.read<String>('stock_location_id');
      final q = l.read<int>('quantity');
      switch (l.read<String>('type')) {
        case 'IN' || 'RETURN' || 'ADJUSTMENT':
          ajouter(produit, magasin, q);
        case 'OUT' || 'LOSS':
          ajouter(produit, magasin, -q);
        case 'TRANSFER':
          ajouter(produit, magasin, -q);
          ajouter(produit, l.read<String?>('counterpart_location_id'), q);
      }
    }
    return effet;
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
                  isWalkIn: Value(l.isWalkIn),
                  stayUnit: Value(l.stayUnit),
                  departureAt: Value(l.departureAt),
                  rateSetBy: Value(l.rateSetBy),
                  bookedRoomTypeId: Value(l.bookedRoomTypeId),
                  upgradeReason: Value(l.upgradeReason),
                  upgradedBy: Value(l.upgradedBy),
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
    final protegesArdoises = {
      ...await _sync.lignesEnAttente(db.folios),
      ...await _ardoisesDeLivraisonsEnAttente(),
    };
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
                // Un serveur plus ancien ne les envoie pas : ne pas effacer
                // ce que la tablette sait de l'ardoise d'un comptoir.
                outletId: Value.absentIfNull(f.outletId),
                tabNumber: Value.absentIfNull(f.tabNumber),
                tabLabel: f.tabLabelConnu
                    ? Value(f.tabLabel)
                    : const Value.absent(),
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
              .insertOnConflictUpdate(_ligne(i, f.id, maintenant));
          itemsEcrits++;
        }
      }
    });

    return (ardoisesEcrites, itemsEcrits, sautes);
  }

  FolioItemsCompanion _ligne(
    RemoteFolioItem i,
    String folioId,
    DateTime maintenant,
  ) => FolioItemsCompanion.insert(
    id: i.id,
    createdAt: maintenant,
    updatedAt: maintenant,
    folioId: folioId,
    category: _categorie(i.category),
    label: i.label,
    quantity: Value(i.quantity),
    unitPrice: Value(i.unitPrice),
    amount: Value(i.amount),
    taxRate: Value(i.taxRate),
    taxAmount: Value(i.taxAmount),
    businessDate: i.businessDate,
    isVoid: Value(i.isVoid),
    // Un serveur plus ancien ne les envoie pas : ne pas effacer ce que la
    // tablette savait deja de la provenance.
    sourceTable: Value.absentIfNull(i.sourceTable),
    sourceId: Value.absentIfNull(i.sourceId),
    postedBy: Value.absentIfNull(i.postedBy),
    postedAt: Value.absentIfNull(i.postedAt),
    syncState: const Value(SyncState.synced),
  );

  // --- Les chambres du comptoir -----------------------------------------------

  /// Les sejours a qui l'agent peut porter, ou `null` s'il ne porte pas
  /// (403) -- ou si le serveur ne connait pas encore la route (404).
  Future<List<RemoteChargeableStay>?> _sejoursAPorter() async {
    try {
      return await _catalog.fetchChargeableStays();
    } on ApiException catch (e) {
      if (e.failure == ApiFailure.forbidden ||
          e.failure == ApiFailure.notFound) {
        return null;
      }
      rethrow;
    }
  }

  /// Ecrit ce qu'il faut pour qu'une chambre se propose au comptoir ; rend
  /// le nombre de sejours ecartes.
  ///
  /// Le strict minimum, et **jamais par-dessus une fiche complete** : une
  /// tablette partagee avec la reception garde ce que la reception y a
  /// descendu. Seuls changent ce que le comptoir doit savoir juste -- le
  /// statut et la chambre du sejour (un changement de chambre), le nom et le
  /// plafond du client.
  ///
  /// Un sejour encore en cours ici et absent de la liste est fini : le
  /// client est parti, sa chambre ne doit plus se proposer -- une charge
  /// portee dessus serait refusee par le serveur et bloquerait la file.
  Future<int> _ecrireSejoursAPorter(
    List<RemoteChargeableStay> sejours,
    DateTime maintenant,
  ) async {
    final protegesClients = await _sync.lignesEnAttente(db.guests);
    final protegesSejours = await _sync.lignesEnAttente(db.reservationRooms);
    final typesConnus = await _identifiants('room_types');
    final chambresConnues = await _identifiants('rooms');
    final clientsConnus = await _identifiants('guests');
    final dossiersConnus = await _identifiants('reservations');
    final sejoursConnus = await _identifiants('reservation_rooms');
    var sautes = 0;

    await db.transaction(() async {
      for (final s in sejours) {
        if (!typesConnus.contains(s.roomTypeId)) {
          await db
              .into(db.roomTypes)
              .insert(
                RoomTypesCompanion.insert(
                  id: s.roomTypeId,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  hotelId: hotelId,
                  code: s.roomTypeCode,
                  label: s.roomTypeLabel,
                  syncState: const Value(SyncState.synced),
                ),
                mode: InsertMode.insertOrIgnore,
              );
          typesConnus.add(s.roomTypeId);
        }
        if (!chambresConnues.contains(s.roomId)) {
          await db
              .into(db.rooms)
              .insert(
                RoomsCompanion.insert(
                  id: s.roomId,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  hotelId: hotelId,
                  number: s.roomNumber,
                  roomTypeId: s.roomTypeId,
                  syncState: const Value(SyncState.synced),
                ),
                mode: InsertMode.insertOrIgnore,
              );
          chambresConnues.add(s.roomId);
        }
        if (!clientsConnus.contains(s.guestId)) {
          await db
              .into(db.guests)
              .insert(
                GuestsCompanion.insert(
                  id: s.guestId,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  hotelId: hotelId,
                  code: s.guestCode,
                  firstName: s.firstName,
                  lastName: s.lastName,
                  creditLimit: Value(s.creditLimit),
                  syncState: const Value(SyncState.synced),
                ),
                mode: InsertMode.insertOrIgnore,
              );
          clientsConnus.add(s.guestId);
        } else if (!protegesClients.contains(s.guestId)) {
          await (db.update(db.guests)..where((g) => g.id.equals(s.guestId)))
              .write(
                GuestsCompanion(
                  firstName: Value(s.firstName),
                  lastName: Value(s.lastName),
                  creditLimit: Value(s.creditLimit),
                ),
              );
        }
        if (!dossiersConnus.contains(s.reservationId)) {
          await db
              .into(db.reservations)
              .insert(
                ReservationsCompanion.insert(
                  id: s.reservationId,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  hotelId: hotelId,
                  reference: s.reservationReference,
                  guestId: s.guestId,
                  status: const Value(ReservationStatus.CHECKED_IN),
                  arrivalDate: s.arrivalDate,
                  departureDate: s.departureDate,
                  syncState: const Value(SyncState.synced),
                ),
                mode: InsertMode.insertOrIgnore,
              );
          dossiersConnus.add(s.reservationId);
        }
        if (protegesSejours.contains(s.stayId)) {
          sautes++;
        } else if (!sejoursConnus.contains(s.stayId)) {
          await db
              .into(db.reservationRooms)
              .insert(
                ReservationRoomsCompanion.insert(
                  id: s.stayId,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  reservationId: s.reservationId,
                  roomTypeId: s.roomTypeId,
                  roomId: Value(s.roomId),
                  arrivalDate: s.arrivalDate,
                  departureDate: s.departureDate,
                  status: const Value(ReservationStatus.CHECKED_IN),
                  checkedInAt: Value(s.checkedInAt),
                  syncState: const Value(SyncState.synced),
                ),
                mode: InsertMode.insertOrIgnore,
              );
        } else {
          await (db.update(
            db.reservationRooms,
          )..where((rr) => rr.id.equals(s.stayId))).write(
            ReservationRoomsCompanion(
              roomId: Value(s.roomId),
              departureDate: Value(s.departureDate),
              status: const Value(ReservationStatus.CHECKED_IN),
            ),
          );
        }
      }

      // Les sejours partis : encore en cours ici, absents du serveur.
      final enCours = {for (final s in sejours) s.stayId};
      final partis =
          await (db.select(db.reservationRooms)..where(
                (rr) =>
                    rr.status.equalsValue(ReservationStatus.CHECKED_IN) &
                    rr.deletedAt.isNull(),
              ))
              .get();
      for (final rr in partis) {
        if (enCours.contains(rr.id) || protegesSejours.contains(rr.id)) {
          continue;
        }
        await (db.update(db.reservationRooms)
              ..where((r) => r.id.equals(rr.id)))
            .write(
              const ReservationRoomsCompanion(
                status: Value(ReservationStatus.CHECKED_OUT),
              ),
            );
      }
    });

    return sautes;
  }

  // --- Les ventes des points de vente -----------------------------------------

  /// L'activite des points de vente de l'agent, ou rien s'il n'a pas le droit
  /// de la lire -- ou si le serveur ne la connait pas encore (404) : une
  /// tablette mise a jour avant son serveur ne doit pas perdre sa descente.
  Future<RemoteOutletActivity> _activitePointsDeVente(DateTime depuis) async {
    try {
      return await _catalog.fetchOutletActivity(depuis);
    } on ApiException catch (e) {
      if (e.failure == ApiFailure.forbidden ||
          e.failure == ApiFailure.notFound) {
        return const RemoteOutletActivity();
      }
      rethrow;
    }
  }

  /// Ecrit les ventes des points de vente ; rend (lignes ecrites, ecartees).
  ///
  /// Une ligne arrive avec l'en-tete seul de son ardoise. S'il manque, il
  /// s'ecrit **sans totaux ni client** : l'agent d'un point de vente ne lit
  /// pas l'ardoise d'une chambre, et la descente complete d'un agent qui la
  /// lit la remplacera. S'il est la, seul son statut suit le serveur --
  /// ecrire des totaux a zero sur une ardoise complete fausserait son solde.
  Future<(int, int)> _ecrireVentesPointsDeVente(
    List<RemoteOutletSale> ventes,
    DateTime maintenant,
  ) async {
    if (ventes.isEmpty) return (0, 0);
    final protegesArdoises = {
      ...await _sync.lignesEnAttente(db.folios),
      ...await _ardoisesDeLivraisonsEnAttente(),
    };
    final protegesLignes = await _sync.lignesEnAttente(db.folioItems);
    final ardoisesConnues = await _identifiants('folios');

    var ecrites = 0;
    var sautees = 0;

    await db.transaction(() async {
      for (final v in ventes) {
        if (protegesLignes.contains(v.item.id)) {
          sautees++;
          continue;
        }
        if (!ardoisesConnues.contains(v.folioId)) {
          await db
              .into(db.folios)
              .insert(
                FoliosCompanion.insert(
                  id: v.folioId,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  hotelId: hotelId,
                  number: v.folioNumber,
                  type: Value(_folioType(v.folioType)),
                  status: Value(_folioStatus(v.folioStatus)),
                  syncState: const Value(SyncState.synced),
                ),
                // Une ardoise effacee ici n'est pas dans les identifiants
                // connus : la laisser telle quelle plutot que faire tomber
                // tout le lot sur la cle primaire.
                mode: InsertMode.insertOrIgnore,
              );
          ardoisesConnues.add(v.folioId);
        } else if (!protegesArdoises.contains(v.folioId)) {
          await (db.update(db.folios)..where((f) => f.id.equals(v.folioId)))
              .write(
                FoliosCompanion(status: Value(_folioStatus(v.folioStatus))),
              );
        }
        await db
            .into(db.folioItems)
            .insertOnConflictUpdate(_ligne(v.item, v.folioId, maintenant));
        ecrites++;
      }
    });

    return (ecrites, sautees);
  }

  // --- Les encaissements -----------------------------------------------------

  /// Combien de jours de ventes closes et d'encaissements chaque descente
  /// relit : de quoi couvrir le mois precedent en entier, sans faire
  /// grossir l'appel de toute l'histoire de l'hotel.
  static const fenetreRapports = 62;

  DateTime _debutFenetreRapports() {
    final jour = businessDayFor(DateTime.now());
    // Composantes et non duree : un changement d'heure decalerait le jour.
    return DateTime(jour.year, jour.month, jour.day - fenetreRapports);
  }

  /// Rend le nombre d'encaissements ecartes (en attente d'envoi ici).
  Future<int> _ecrireEncaissements(
    List<RemotePayment> encaissements,
    DateTime maintenant,
  ) async {
    final proteges = await _sync.lignesEnAttente(db.payments);
    var sautes = 0;

    await db.transaction(() async {
      for (final p in encaissements) {
        // La version locale fait foi tant qu'elle n'est pas remontee.
        // Un moyen inconnu de cette version : le ranger en especes fausserait
        // la caisse, mieux vaut l'ecarter.
        final moyen = _moyen(p.method);
        if (proteges.contains(p.id) || moyen == null) {
          sautes++;
          continue;
        }
        await db
            .into(db.payments)
            .insertOnConflictUpdate(
              PaymentsCompanion.insert(
                id: p.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                method: moyen,
                amount: p.amount,
                folioId: Value(p.folioId),
                cashSessionId: Value(p.cashSessionId),
                reference: Value(p.reference),
                receivedBy: Value(p.receivedBy),
                receivedAt: Value(p.receivedAt),
                businessDate: Value(p.businessDate),
                isRefund: Value(p.isRefund),
                reversesPaymentId: Value(p.reversesPaymentId),
                // Sans la note, des arrhes ne se reconnaissaient plus au
                // check-in : elles restaient hors de l'ardoise, la tablette
                // croyait le sejour entier du, et l'encaissement du tout
                // etait refuse par le serveur (vecu le 11 octobre). Un
                // serveur qui ne l'envoie pas ne l'efface pas non plus.
                notes: p.notes == null
                    ? const Value.absent()
                    : Value(p.notes),
                syncState: const Value(SyncState.synced),
              ),
            );
      }
    });
    return sautes;
  }

  // --- Les inventaires -------------------------------------------------------

  /// Rend le nombre d'inventaires ecartes : en attente d'envoi ici (un
  /// comptage pas encore remonte fait foi), ou d'un etat que cette version
  /// ne connait pas.
  ///
  /// Un comptage part dans la file sous l'id de l'inventaire : c'est donc
  /// l'inventaire entier, lignes comprises, qu'on epargne.
  Future<int> _ecrireInventaires(
    List<RemoteInventory> inventaires,
    DateTime maintenant,
  ) async {
    final proteges = await _sync.lignesEnAttente(db.inventories);
    var sautes = 0;
    await db.transaction(() async {
      for (final inv in inventaires) {
        final etat = InventoryStatus.values
            .where((s) => s.name == inv.status)
            .firstOrNull;
        if (proteges.contains(inv.id) || etat == null) {
          sautes++;
          continue;
        }
        await db
            .into(db.inventories)
            .insertOnConflictUpdate(
              InventoriesCompanion.insert(
                id: inv.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                deletedAt: Value(inv.deletedAt),
                createdBy: Value(inv.createdBy),
                hotelId: hotelId,
                stockLocationId: inv.stockLocationId,
                label: inv.label,
                status: Value(etat),
                inventoryDate: Value(inv.inventoryDate),
                startedAt: Value(inv.startedAt),
                closedAt: Value(inv.closedAt),
                closedBy: Value(inv.closedBy),
                syncState: const Value(SyncState.synced),
              ),
            );
        for (final l in inv.lines) {
          await db
              .into(db.inventoryLines)
              .insertOnConflictUpdate(
                InventoryLinesCompanion.insert(
                  id: l.id,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  inventoryId: inv.id,
                  productId: l.productId,
                  theoreticalQty: Value(l.theoreticalQty),
                  countedQty: Value(l.countedQty),
                  variance: Value(l.variance),
                  syncState: const Value(SyncState.synced),
                ),
              );
        }
      }
    });
    return sautes;
  }

  // --- Les commandes en chambre ------------------------------------------------

  /// Les ardoises sur lesquelles une livraison attend de remonter.
  ///
  /// La tablette qui livre ecrit les lignes sur l'ardoise sans les enfiler :
  /// c'est le serveur qui les ecrira, a la reception de la livraison. D'ici
  /// la, son ardoise ne les a pas, et la descente ecraserait le solde local
  /// avec un solde sans elles. La livraison en attente protege l'ardoise.
  Future<Set<String>> _ardoisesDeLivraisonsEnAttente() async {
    final lignes = await db
        .customSelect(
          '''
      SELECT o.folio_id AS id
        FROM outbox_entries e
        JOIN orders o ON o.id = e.entity_id
       WHERE e.entity_table = 'orders'
         AND e.status IN ('PENDING','FAILED')
         AND json_extract(e.payload, '\$.action') = 'DELIVER'
         AND o.folio_id IS NOT NULL
      ''',
          readsFrom: {db.outboxEntries, db.orders},
        )
        .get();
    return {for (final l in lignes) l.read<String>('id')};
  }

  /// Ecrit les commandes en chambre ; rend le nombre de commandes ecartees.
  ///
  /// Une commande qui a un geste en attente ici est epargnee en entier,
  /// lignes comprises : la version locale fait foi tant qu'elle n'est pas
  /// remontee. L'ardoise d'une chambre n'est pas sur la tablette du bar --
  /// il ne lit pas les ardoises : pour une commande en route, son en-tete
  /// s'ecrit seul, sans totaux, comme pour les ventes des points de vente.
  /// La livraison y posera ses lignes.
  Future<int> _ecrireCommandesEnChambre(
    List<RemoteRoomOrder> commandes,
    DateTime maintenant,
  ) async {
    if (commandes.isEmpty) return 0;
    final proteges = await _sync.lignesEnAttente(db.orders);
    final ardoisesConnues = await _identifiants('folios');
    var sautes = 0;
    await db.transaction(() async {
      for (final c in commandes) {
        final statut = OrderStatus.values
            .where((s) => s.name == c.status)
            .firstOrNull;
        if (proteges.contains(c.id) || statut == null) {
          sautes++;
          continue;
        }
        final enRoute = RoomOrderRepository.enCours.contains(statut);
        if (enRoute &&
            c.folioId != null &&
            !ardoisesConnues.contains(c.folioId)) {
          await db
              .into(db.folios)
              .insert(
                FoliosCompanion.insert(
                  id: c.folioId!,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  hotelId: hotelId,
                  number: codeFromId(c.folioId!, 'FOL'),
                  guestId: Value(c.guestId),
                  syncState: const Value(SyncState.synced),
                ),
                mode: InsertMode.insertOrIgnore,
              );
          ardoisesConnues.add(c.folioId!);
        }
        await db
            .into(db.orders)
            .insertOnConflictUpdate(
              OrdersCompanion.insert(
                id: c.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                number: c.number.isEmpty ? codeFromId(c.id, 'ORD') : c.number,
                outletId: c.outletId,
                type: const Value(OrderType.ROOM_SERVICE),
                status: Value(statut),
                roomId: Value(c.roomId),
                folioId: Value(c.folioId),
                guestId: Value(c.guestId),
                businessDate: Value(c.businessDate),
                openedAt: Value(c.openedAt),
                sentAt: Value(c.openedAt),
                servedAt: Value(c.servedAt),
                cancelledAt: Value(c.cancelledAt),
                cancelReason: Value(c.cancelReason),
                subtotal: Value(c.total),
                taxTotal: Value(c.taxTotal),
                total: Value(c.total),
                notes: Value(c.notes),
                orderedBy: Value(c.orderedBy),
                takenBy: Value(c.takenBy),
                takenAt: Value(c.takenAt),
                deliveredBy: Value(c.deliveredBy),
                cancelledBy: Value(c.cancelledBy),
                overrideBy: Value(c.overrideBy),
                syncState: const Value(SyncState.synced),
              ),
            );
        for (var i = 0; i < c.items.length; i++) {
          final l = c.items[i];
          final etat = OrderStatus.values
              .where((s) => s.name == l.status)
              .firstOrNull;
          await db
              .into(db.orderItems)
              .insertOnConflictUpdate(
                OrderItemsCompanion.insert(
                  id: l.id,
                  createdAt: maintenant,
                  updatedAt: maintenant,
                  orderId: c.id,
                  menuItemId: Value(l.menuItemId),
                  prepStationId: Value(l.prepStationId),
                  labelSnapshot: l.label,
                  quantity: Value(l.quantity),
                  unitPrice: Value(l.unitPrice),
                  taxRate: Value(l.taxRate),
                  amount: Value(l.amount),
                  status: Value(etat ?? statut),
                  notes: Value(l.notes),
                  sortOrder: Value(i),
                  syncState: const Value(SyncState.synced),
                ),
              );
        }
      }
    });
    return sautes;
  }

  // --- Les depenses ----------------------------------------------------------

  /// Rend le nombre de depenses ecartees : en attente d'envoi ici, ou d'une
  /// rubrique que cette version ne connait pas (la ranger en « Autre »
  /// fausserait la repartition sans le dire).
  Future<int> _ecrireDepenses(
    List<RemoteExpense> depenses,
    DateTime maintenant,
  ) async {
    final protegees = await _sync.lignesEnAttente(db.expenses);
    var sautees = 0;
    await db.transaction(() async {
      for (final d in depenses) {
        final rubrique = _rubrique(d.category);
        if (protegees.contains(d.id) || rubrique == null) {
          sautees++;
          continue;
        }
        await db
            .into(db.expenses)
            .insertOnConflictUpdate(
              ExpensesCompanion.insert(
                id: d.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                businessDate: d.businessDate,
                category: rubrique,
                label: d.label,
                amount: d.amount,
                method: Value(d.method == null ? null : _moyen(d.method!)),
                supplier: Value(d.supplier),
                reference: Value(d.reference),
                notes: Value(d.notes),
                recordedBy: Value(d.recordedBy),
                isVoid: Value(d.isVoid),
                voidReason: Value(d.voidReason),
                voidedBy: Value(d.voidedBy),
                syncState: const Value(SyncState.synced),
              ),
            );
      }
    });
    return sautees;
  }

  /// Remplace les couts de la fenetre : un jour que le serveur ne rend plus
  /// (tout y a ete annule) ne doit pas garder son ancien total.
  Future<void> _ecrireCouts(
    List<RemoteDailyCost> couts,
    DateTime depuis,
    DateTime maintenant,
  ) async {
    final premier = _jourTexte(depuis);
    await db.transaction(() async {
      await (db.delete(
        db.dailyCosts,
      )..where((c) => c.businessDate.isBiggerOrEqualValue(premier))).go();
      for (final c in couts) {
        await db
            .into(db.dailyCosts)
            .insertOnConflictUpdate(
              DailyCostsCompanion.insert(
                businessDate: c.businessDate,
                costOfSales: Value(c.costOfSales),
                consumption: Value(c.consumption),
                losses: Value(c.losses),
                purchases: Value(c.purchases),
                updatedAt: maintenant,
              ),
            );
      }
    });
  }

  static String _jourTexte(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static ExpenseCategory? _rubrique(String v) {
    for (final c in ExpenseCategory.values) {
      if (c.name == v) return c;
    }
    return null;
  }

  // --- Les caisses -----------------------------------------------------------

  /// Rend le nombre de caisses ecartees (en attente d'envoi ici).
  ///
  /// Une caisse ouverte, fermee ou confirmee sur cette tablette et pas encore
  /// remontee garde sa version locale : le serveur la croit encore ouverte,
  /// et l'ecrire rouvrirait un tiroir que l'agent vient de vider.
  Future<int> _ecrireCaisses(
    List<RemoteCashSession> caisses,
    DateTime maintenant,
  ) async {
    final protegees = await _sync.lignesEnAttente(db.cashSessions);
    var sautees = 0;

    final depotCaisse = CashRepository(db);

    await db.transaction(() async {
      for (final c in caisses) {
        if (protegees.contains(c.id)) {
          sautees++;
          continue;
        }
        // Un agent n'a qu'une caisse ouverte. Si la tablette lui en connait
        // une autre -- ouverte ici avant que l'ouverture ne porte son
        // identifiant, donc nee sous un autre sur le serveur -- c'est la
        // meme : elle prend l'identifiant du serveur. Encore en attente
        // d'envoi, elle le prendra a la reponse ; d'ici la, ecrire celle du
        // serveur a cote ferait deux tiroirs ouverts pour un seul agent.
        if (c.status == CashSessionStatus.OPEN.name) {
          final locale = await depotCaisse.openSessionId(
            c.userId,
            outletId: c.outletId,
          );
          if (locale != null && locale != c.id) {
            if (protegees.contains(locale)) {
              sautees++;
              continue;
            }
            await depotCaisse.adoptServerSession(
              localId: locale,
              serverId: c.id,
            );
          }
        }
        await db
            .into(db.cashSessions)
            .insertOnConflictUpdate(
              CashSessionsCompanion.insert(
                id: c.id,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: hotelId,
                userId: c.userId,
                status: Value(
                  c.status == CashSessionStatus.OPEN.name
                      ? CashSessionStatus.OPEN
                      : CashSessionStatus.CLOSED,
                ),
                openedAt: Value(c.openedAt),
                openingFloat: Value(c.openingFloat),
                closedAt: Value(c.closedAt),
                countedAmount: Value(c.countedAmount),
                expectedAmount: Value(c.expectedAmount),
                variance: Value(c.variance),
                outletId: Value(c.outletId),
                receivedAmount: Value(c.receivedAmount),
                receivedBy: Value(c.receivedBy),
                receivedAt: Value(c.receivedAt),
                receivedSessionId: Value(c.receivedSessionId),
                syncState: const Value(SyncState.synced),
              ),
            );
      }
    });
    return sautees;
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

  static PaymentMethod? _moyen(String v) {
    for (final m in PaymentMethod.values) {
      if (m.name == v) return m;
    }
    return null;
  }

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