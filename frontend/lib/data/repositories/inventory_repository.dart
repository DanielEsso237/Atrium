/// L'inventaire d'un magasin (demande du 15 octobre).
///
/// Le charge d'inventaire ouvre l'inventaire d'un magasin -- l'economat, le
/// bar... --, compte sur le terrain et saisit ce qu'il trouve ; l'ecran
/// montre l'ecart avec le stock de la machine. Un responsable « reequilibre » :
/// le stock theorique s'aligne sur le reel.
///
/// Decisions de Daniel (15 octobre) :
/// - un magasin a la fois, un seul inventaire ouvert par magasin ;
/// - la quantite theorique est **figee a l'ouverture** : on compte magasin
///   ferme, et ce qui se vend apres l'ouverture reste vendu ;
/// - deux droits : `stock.inventory` (compter) et `stock.rebalance`
///   (reequilibrer) ;
/// - au reequilibrage, un manque devient une **perte** (`LOSS`, visible dans
///   le benefice), un surplus un **ajustement** (`ADJUSTMENT`).
///
/// Tout se fait hors ligne et part dans la file (`/inventories...`). Ce que
/// le serveur refuserait est refuse ici d'abord.
library;

import 'package:drift/drift.dart';

import '../../core/business_day.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// Une ligne du tableau : l'article, la machine, le terrain, l'ecart.
class LigneInventaire {
  const LigneInventaire({
    required this.productId,
    required this.libelle,
    required this.unite,
    required this.theorique,
    this.compte,
  });

  final String productId;
  final String libelle;
  final String unite;

  /// Ce que la machine comptait a l'ouverture.
  final int theorique;

  /// Ce que le charge d'inventaire a trouve ; `null` : pas encore compte.
  final int? compte;

  /// Compte moins theorique : negatif, il manque ; positif, il y a en trop.
  int? get ecart => compte == null ? null : compte! - theorique;
}

/// Un inventaire ouvert, tel que l'ecran le montre.
class Inventaire {
  const Inventaire({
    required this.id,
    required this.magasinId,
    required this.libelle,
    required this.lignes,
    this.ouvertLe,
  });

  final String id;
  final String magasinId;
  final String libelle;
  final List<LigneInventaire> lignes;
  final DateTime? ouvertLe;

  int get comptees => lignes.where((l) => l.compte != null).length;

  /// Les lignes comptees qui ont un ecart : ce que le reequilibrage changera.
  List<LigneInventaire> get ecarts => [
    for (final l in lignes)
      if (l.ecart != null && l.ecart != 0) l,
  ];
}

class InventoryRepository with OutboxWriter {
  InventoryRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  /// L'inventaire ouvert de ce magasin, ou `null` s'il n'y en a pas.
  Stream<Inventaire?> watchOuvert(String magasinId) {
    final entete =
        (db.select(db.inventories)
              ..where(
                (i) =>
                    i.stockLocationId.equals(magasinId) &
                    i.deletedAt.isNull() &
                    i.status.equalsValue(InventoryStatus.CLOSED).not(),
              )
              ..limit(1))
            .watchSingleOrNull();
    return entete.asyncExpand((inv) {
      if (inv == null) return Stream.value(null);
      return db
          .customSelect(
            '''
        SELECT l.product_id, l.theoretical_qty, l.counted_qty,
               p.label, p.unit
          FROM inventory_lines l
          JOIN products p ON p.id = l.product_id
         WHERE l.inventory_id = ?1 AND l.deleted_at IS NULL
         ORDER BY p.label
        ''',
            variables: [Variable.withString(inv.id)],
            readsFrom: {db.inventoryLines, db.products},
          )
          .watch()
          .map(
            (rangs) => Inventaire(
              id: inv.id,
              magasinId: magasinId,
              libelle: inv.label,
              ouvertLe: inv.startedAt,
              lignes: [
                for (final r in rangs)
                  LigneInventaire(
                    productId: r.read<String>('product_id'),
                    libelle: r.read<String>('label'),
                    unite: r.read<String>('unit'),
                    theorique: r.read<int>('theoretical_qty'),
                    compte: r.readNullable<int>('counted_qty'),
                  ),
              ],
            ),
          );
    });
  }

  /// Ouvre l'inventaire d'un magasin ; rend son identifiant.
  ///
  /// Une ligne par produit qui a un stock dans ce magasin, sa quantite
  /// theorique figee maintenant. Le serveur fige la sienne a reception : la
  /// tablette peut etre en retard d'une vente faite ailleurs.
  Future<String> ouvrir({required String magasinId, required String by}) async {
    final magasin = await (db.select(
      db.stockLocations,
    )..where((m) => m.id.equals(magasinId))).getSingleOrNull();
    if (magasin == null || magasin.deletedAt != null) {
      throw StateError('Magasin introuvable.');
    }
    final deja =
        await (db.select(db.inventories)
              ..where(
                (i) =>
                    i.stockLocationId.equals(magasinId) &
                    i.deletedAt.isNull() &
                    i.status.equalsValue(InventoryStatus.CLOSED).not(),
              )
              ..limit(1))
            .getSingleOrNull();
    if (deja != null) {
      throw StateError(
        'Un inventaire est déjà ouvert pour ${magasin.label} : terminez-le '
        'ou abandonnez-le d’abord.',
      );
    }
    final niveaux =
        await (db.select(db.stockLevels)
              ..where((l) => l.stockLocationId.equals(magasinId)))
            .get();
    final produits = {
      for (final p in await (db.select(
        db.products,
      )..where((p) => p.deletedAt.isNull())).get())
        p.id,
    };
    final lignes = [
      for (final n in niveaux)
        if (produits.contains(n.productId))
          (id: newId(), produit: n.productId, quantite: n.quantity),
    ];
    if (lignes.isEmpty) {
      throw StateError('${magasin.label} n’a aucun article en stock à compter.');
    }

    final id = newId();
    final now = DateTime.now().toUtc();
    final libelle = 'Inventaire ${magasin.label}';
    await db.transaction(() async {
      await db
          .into(db.inventories)
          .insert(
            InventoriesCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              stockLocationId: magasinId,
              label: libelle,
              status: const Value(InventoryStatus.COUNTING),
              inventoryDate: Value(businessDateNow()),
              startedAt: Value(now),
              createdBy: Value(by),
              syncState: const Value(SyncState.pending),
            ),
          );
      for (final l in lignes) {
        await db
            .into(db.inventoryLines)
            .insert(
              InventoryLinesCompanion.insert(
                id: l.id,
                createdAt: now,
                updatedAt: now,
                inventoryId: id,
                productId: l.produit,
                theoreticalQty: Value(l.quantite),
                // Remontent avec l'inventaire, pas a part.
                syncState: const Value(SyncState.synced),
              ),
            );
      }
      await enqueue(
        table: 'inventories',
        id: id,
        operation: SyncOp.INSERT,
        payload: {
          'id': id,
          'action': 'OPEN',
          'stock_location_id': magasinId,
          'label': libelle,
          'lines': [
            for (final l in lignes) {'id': l.id, 'product_id': l.produit},
          ],
        },
      );
    });
    return id;
  }

  /// Saisit ce qui a ete compte pour un article ; `null` efface le comptage.
  Future<void> compter({
    required String inventaireId,
    required String productId,
    required int? quantite,
  }) async {
    if (quantite != null && quantite < 0) {
      throw StateError('Une quantité comptée ne peut pas être négative.');
    }
    final inv = await _ouvert(inventaireId);
    final ligne =
        await (db.select(db.inventoryLines)..where(
              (l) =>
                  l.inventoryId.equals(inv.id) & l.productId.equals(productId),
            ))
            .getSingleOrNull();
    if (ligne == null) throw StateError('Article absent de cet inventaire.');
    if (ligne.countedQty == quantite) return;
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(
        db.inventoryLines,
      )..where((l) => l.id.equals(ligne.id))).write(
        InventoryLinesCompanion(
          countedQty: Value(quantite),
          variance: Value(quantite == null ? 0 : quantite - ligne.theoreticalQty),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );
      await enqueue(
        table: 'inventories',
        id: inv.id,
        operation: SyncOp.UPDATE,
        payload: {
          'id': inv.id,
          'action': 'COUNT',
          'product_id': productId,
          'counted_qty': quantite,
        },
      );
    });
  }

  /// Reequilibre : le stock du magasin s'aligne sur ce qui a ete compte.
  ///
  /// Chaque ligne comptee avec un ecart donne un mouvement : une perte pour
  /// un manque, un ajustement pour un surplus. Les lignes non comptees ne
  /// bougent pas. L'inventaire se clot. Rend le nombre d'articles corriges.
  Future<int> reequilibrer({
    required String inventaireId,
    required String by,
  }) async {
    final inv = await _ouvert(inventaireId);
    final lignes =
        await (db.select(db.inventoryLines)..where(
              (l) =>
                  l.inventoryId.equals(inv.id) &
                  l.deletedAt.isNull() &
                  l.countedQty.isNotNull(),
            ))
            .get();
    if (lignes.isEmpty) {
      throw StateError('Comptez au moins un article avant de rééquilibrer.');
    }
    final now = DateTime.now().toUtc();
    final mouvements = <String, String>{};
    await db.transaction(() async {
      for (final l in lignes) {
        final ecart = l.countedQty! - l.theoreticalQty;
        if (ecart == 0) continue;
        final id = newId();
        mouvements[l.productId] = id;
        await db
            .into(db.stockMovements)
            .insert(
              StockMovementsCompanion.insert(
                id: id,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                productId: l.productId,
                stockLocationId: inv.stockLocationId,
                type: ecart < 0
                    ? StockMovementType.LOSS
                    : StockMovementType.ADJUSTMENT,
                // Une perte se compte en positif, comme toute sortie ; un
                // ajustement porte son signe.
                quantity: ecart < 0 ? -ecart : ecart,
                reason: Value(inv.label),
                movedAt: Value(now),
                movedBy: Value(by),
                status: const Value(StockMovementStatus.APPROVED),
                // Cree par le serveur au reequilibrage, avec cet identifiant :
                // il ne remonte pas a part.
                syncState: const Value(SyncState.synced),
              ),
            );
        await _ajouter(l.productId, inv.stockLocationId, ecart, now);
      }
      await (db.update(
        db.inventories,
      )..where((i) => i.id.equals(inv.id))).write(
        InventoriesCompanion(
          status: const Value(InventoryStatus.CLOSED),
          closedAt: Value(now),
          closedBy: Value(by),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );
      await enqueue(
        table: 'inventories',
        id: inv.id,
        operation: SyncOp.UPDATE,
        payload: {
          'id': inv.id,
          'action': 'REBALANCE',
          'movement_ids': mouvements,
        },
      );
    });
    return mouvements.length;
  }

  /// Abandonne un inventaire ouvert : rien ne bouge dans le stock.
  Future<void> abandonner(String inventaireId) async {
    final inv = await _ouvert(inventaireId);
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(
        db.inventories,
      )..where((i) => i.id.equals(inv.id))).write(
        InventoriesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );
      await enqueue(
        table: 'inventories',
        id: inv.id,
        operation: SyncOp.UPDATE,
        payload: {'id': inv.id, 'action': 'CANCEL'},
      );
    });
  }

  Future<InventoryRow> _ouvert(String inventaireId) async {
    final inv = await (db.select(
      db.inventories,
    )..where((i) => i.id.equals(inventaireId))).getSingleOrNull();
    if (inv == null || inv.deletedAt != null) {
      throw StateError('Inventaire introuvable.');
    }
    if (inv.status == InventoryStatus.CLOSED) {
      throw StateError('Cet inventaire est déjà clos.');
    }
    return inv;
  }

  /// Ajoute (ou retire) au compteur d'un magasin.
  Future<void> _ajouter(
    String productId,
    String placeId,
    int delta,
    DateTime now,
  ) async {
    final existant =
        await (db.select(db.stockLevels)..where(
              (l) =>
                  l.productId.equals(productId) &
                  l.stockLocationId.equals(placeId),
            ))
            .getSingleOrNull();
    if (existant == null) {
      await db
          .into(db.stockLevels)
          .insert(
            StockLevelsCompanion.insert(
              id: newId(),
              createdAt: now,
              updatedAt: now,
              productId: productId,
              stockLocationId: placeId,
              quantity: Value(delta),
              lastMovementAt: Value(now),
            ),
          );
    } else {
      await (db.update(
        db.stockLevels,
      )..where((l) => l.id.equals(existant.id))).write(
        StockLevelsCompanion(
          quantity: Value(existant.quantity + delta),
          lastMovementAt: Value(now),
          updatedAt: Value(now),
        ),
      );
    }
  }
}
