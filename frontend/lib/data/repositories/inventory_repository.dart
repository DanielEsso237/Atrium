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
    this.motif,
  });

  final String productId;
  final String libelle;
  final String unite;

  /// Ce que la machine comptait a l'ouverture.
  final int theorique;

  /// Ce que le charge d'inventaire a trouve ; `null` : pas encore compte.
  final int? compte;

  /// Pourquoi l'ecart : casse, vol, erreur de saisie (reunion du 18
  /// octobre). Saisi a cote de l'ecart, pas a la place du comptage.
  final String? motif;

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
  ///
  /// Une seule lecture, en-tete et lignes ensemble : elle se relance a
  /// chaque changement de l'un ou des autres. Avant, les lignes s'ecoutaient
  /// a part, accrochees au premier en-tete lu (`asyncExpand`) : un inventaire
  /// abandonne ou clos restait a l'ecran, et chaque geste repondait
  /// « Inventaire introuvable » (15 octobre).
  Stream<Inventaire?> watchOuvert(String magasinId) {
    return db
        .customSelect(
          '''
      WITH ouvert AS (
        SELECT id, label, started_at FROM inventories
         WHERE stock_location_id = ?1
           AND deleted_at IS NULL
           AND status <> 'CLOSED'
         ORDER BY created_at
         LIMIT 1
      )
      SELECT o.id AS inventaire, o.label AS libelle_inventaire,
             o.started_at AS ouvert_le,
             l.product_id, l.theoretical_qty, l.counted_qty, l.comment,
             p.label, p.unit
        FROM ouvert o
        LEFT JOIN inventory_lines l
               ON l.inventory_id = o.id AND l.deleted_at IS NULL
        LEFT JOIN products p ON p.id = l.product_id
       ORDER BY p.label
      ''',
          variables: [Variable.withString(magasinId)],
          readsFrom: {db.inventories, db.inventoryLines, db.products},
        )
        .watch()
        .map((rangs) {
          if (rangs.isEmpty) return null;
          final premier = rangs.first;
          return Inventaire(
            id: premier.read<String>('inventaire'),
            magasinId: magasinId,
            libelle: premier.read<String>('libelle_inventaire'),
            ouvertLe: premier.readNullable<DateTime>('ouvert_le'),
            lignes: [
              for (final r in rangs)
                if (r.readNullable<String>('product_id') != null &&
                    r.readNullable<String>('label') != null)
                  LigneInventaire(
                    productId: r.read<String>('product_id'),
                    libelle: r.read<String>('label'),
                    unite: r.read<String>('unit'),
                    theorique: r.read<int>('theoretical_qty'),
                    compte: r.readNullable<int>('counted_qty'),
                    motif: r.readNullable<String>('comment'),
                  ),
            ],
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
          // Le motif deja note suit le comptage. Absent, le serveur garde
          // celui qu'il a.
          if (ligne.comment != null) 'comment': ligne.comment,
        },
      );
    });
  }

  /// Le refus du reequilibrage tant que des ecarts n'ont pas leur motif,
  /// avec les articles a reprendre.
  Future<String> motifsManquants(List<String> productIds) async {
    final produits = await (db.select(
      db.products,
    )..where((p) => p.id.isIn(productIds))).get();
    final noms = [for (final p in produits) p.label]..sort();
    final n = productIds.length;
    return n == 1
        ? 'Un écart n’a pas de motif (${noms.join(', ')}) : notez-le avant '
              'de rééquilibrer.'
        : '$n écarts n’ont pas de motif (${noms.join(', ')}) : notez-les '
              'avant de rééquilibrer.';
  }

  /// Note le motif de l'ecart d'une ligne comptee (reunion du 18 octobre) :
  /// vide, il s'efface. Il part avec le comptage, par la meme route.
  Future<void> noterMotif({
    required String inventaireId,
    required String productId,
    required String? motif,
  }) async {
    final texte = motif?.trim();
    final valeur = texte == null || texte.isEmpty ? null : texte;
    if (valeur != null && valeur.length > 255) {
      throw StateError('Le motif tient en 255 caractères.');
    }
    final inv = await _ouvert(inventaireId);
    final ligne =
        await (db.select(db.inventoryLines)..where(
              (l) =>
                  l.inventoryId.equals(inv.id) & l.productId.equals(productId),
            ))
            .getSingleOrNull();
    if (ligne == null) throw StateError('Article absent de cet inventaire.');
    if (ligne.countedQty == null) {
      throw StateError('Comptez l’article avant de noter le motif de l’écart.');
    }
    if (ligne.comment == valeur) return;
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(
        db.inventoryLines,
      )..where((l) => l.id.equals(ligne.id))).write(
        InventoryLinesCompanion(
          comment: Value(valeur),
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
          'counted_qty': ligne.countedQty,
          'comment': valeur,
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
    // Chaque ecart dit son motif avant que le stock ne bouge (decision du
    // client, 18 octobre) : une perte sans explication ne se valide pas.
    final sansMotif = [
      for (final l in lignes)
        if (l.countedQty != l.theoreticalQty &&
            (l.comment == null || l.comment!.trim().isEmpty))
          l.productId,
    ];
    if (sansMotif.isNotEmpty) {
      throw StateError(await motifsManquants(sansMotif));
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
