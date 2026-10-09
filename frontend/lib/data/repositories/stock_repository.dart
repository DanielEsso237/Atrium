/// Les stocks sur la tablette : l'economat, le stock de chaque point de
/// vente, les entrees, les transferts et leur validation.
///
/// L'economat est le stock principal : il ravitaille les points de vente, qui
/// se ravitaillent aussi entre eux. Un transfert attend la validation du
/// controleur ou du comptable (un seul suffit) ; le stock ne bouge qu'a ce
/// moment-la.
///
/// Le stock peut passer sous zero (decision du 8 octobre : on vend, et
/// l'econome est alerte). Rien ici ne refuse un mouvement faute de stock :
/// l'ecran previent, l'agent decide.
library;

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// Un magasin, tel que l'ecran le liste.
class StockPlace {
  const StockPlace({
    required this.id,
    required this.label,
    required this.isCentral,
    this.outletId,
  });

  final String id;
  final String label;
  final bool isCentral;
  final String? outletId;
}

/// Un produit dans un magasin, avec de quoi alerter.
class StockLine {
  const StockLine({
    required this.productId,
    required this.label,
    required this.reference,
    required this.unit,
    required this.quantity,
    required this.minStock,
    required this.purchasePrice,
  });

  final String productId;
  final String label;
  final String reference;
  final String unit;
  final int quantity;
  final int minStock;
  final int purchasePrice;

  /// Sous zero : le stock theorique ment, une livraison ou une casse n'a pas
  /// ete saisie.
  bool get isNegative => quantity < 0;

  /// Sous le seuil d'alerte du produit : il faut ravitailler.
  bool get isLow => !isNegative && minStock > 0 && quantity < minStock;
}

/// Un transfert qui attend sa validation.
class PendingTransfer {
  const PendingTransfer({
    required this.id,
    required this.productLabel,
    required this.unit,
    required this.quantity,
    required this.fromLabel,
    required this.toLabel,
    required this.availableAtSource,
    this.movedAt,
  });

  final String id;
  final String productLabel;
  final String unit;
  final int quantity;
  final String fromLabel;
  final String toLabel;

  /// Ce que le magasin de depart a, pour que le valideur voie s'il se vide.
  final int availableAtSource;
  final DateTime? movedAt;
}

/// Un produit propose dans les formulaires.
class StockProduct {
  const StockProduct({
    required this.id,
    required this.label,
    required this.unit,
    required this.purchasePrice,
  });

  final String id;
  final String label;
  final String unit;
  final int purchasePrice;
}

class StockRepository with OutboxWriter {
  StockRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  // --- Lectures -------------------------------------------------------------

  /// Les magasins : l'economat d'abord, puis dans leur ordre.
  ///
  /// Un agent rattache a des points de vente (le barman) ne voit que leurs
  /// magasins : le stock du bar, pas celui de la boite ni l'economat. Un agent
  /// sans rattachement (administration, econome) voit tout -- meme regle que
  /// les onglets de l'ecran Points de vente.
  Stream<List<StockPlace>> watchPlaces({String? agentId}) {
    final q = db.select(db.stockLocations)
      ..where(
        (m) =>
            m.deletedAt.isNull() &
            m.isActive.equals(true) &
            (agentId == null
                ? const Constant(true)
                : CustomExpression<bool>(
                    '(NOT EXISTS (SELECT 1 FROM user_outlets uo '
                    "WHERE uo.user_id = '${agentId.replaceAll("'", "''")}') "
                    'OR stock_locations.outlet_id IN (SELECT uo.outlet_id FROM '
                    "user_outlets uo WHERE uo.user_id = '${agentId.replaceAll("'", "''")}'))",
                    watchedTables: [db.userOutlets],
                  )),
      )
      ..orderBy([
        (m) => OrderingTerm.desc(m.isCentral),
        (m) => OrderingTerm.asc(m.sortOrder),
        (m) => OrderingTerm.asc(m.label),
      ]);
    return q.watch().map(
      (rows) => [
        for (final m in rows)
          StockPlace(
            id: m.id,
            label: m.label,
            isCentral: m.isCentral,
            outletId: m.outletId,
          ),
      ],
    );
  }

  /// Les produits d'un magasin et leur quantite : ceux qui y ont un stock,
  /// et tous les produits a l'economat (pour voir ce qui manque).
  Stream<List<StockLine>> watchLines(String placeId, {bool allProducts = false}) {
    return db
        .customSelect(
          '''
      SELECT p.id, p.label, p.reference, p.unit, p.min_stock, p.purchase_price,
             COALESCE(l.quantity, 0) AS quantity
        FROM products p
        ${allProducts ? 'LEFT' : ''} JOIN stock_levels l
               ON l.product_id = p.id AND l.stock_location_id = ?1
       WHERE p.deleted_at IS NULL
       ORDER BY p.label
      ''',
          variables: [Variable.withString(placeId)],
          readsFrom: {db.products, db.stockLevels},
        )
        .watch()
        .map(
          (rows) => [
            for (final r in rows)
              StockLine(
                productId: r.read<String>('id'),
                label: r.read<String>('label'),
                reference: r.read<String>('reference'),
                unit: r.read<String>('unit'),
                quantity: r.read<int>('quantity'),
                minStock: r.read<int>('min_stock'),
                purchasePrice: r.read<int>('purchase_price'),
              ),
          ],
        );
  }

  /// Les produits, pour les formulaires d'entree et de transfert.
  Stream<List<StockProduct>> watchProducts() {
    final q = db.select(db.products)
      ..where((p) => p.deletedAt.isNull())
      ..orderBy([(p) => OrderingTerm.asc(p.label)]);
    return q.watch().map(
      (rows) => [
        for (final p in rows)
          StockProduct(
            id: p.id,
            label: p.label,
            unit: p.unit,
            purchasePrice: p.purchasePrice,
          ),
      ],
    );
  }

  /// Les transferts qui attendent une validation.
  Stream<List<PendingTransfer>> watchPendingTransfers() {
    return db
        .customSelect(
          '''
      SELECT m.id, m.quantity, m.moved_at,
             p.label AS product_label, p.unit,
             src.label AS from_label, dst.label AS to_label,
             COALESCE(l.quantity, 0) AS available
        FROM stock_movements m
        JOIN products p          ON p.id = m.product_id
        JOIN stock_locations src ON src.id = m.stock_location_id
        JOIN stock_locations dst ON dst.id = m.counterpart_location_id
        LEFT JOIN stock_levels l ON l.product_id = m.product_id
                                AND l.stock_location_id = m.stock_location_id
       WHERE m.deleted_at IS NULL
         AND m.type = 'TRANSFER' AND m.status = 'PENDING'
       ORDER BY m.moved_at
      ''',
          readsFrom: {
            db.stockMovements,
            db.products,
            db.stockLocations,
            db.stockLevels,
          },
        )
        .watch()
        .map(
          (rows) => [
            for (final r in rows)
              PendingTransfer(
                id: r.read<String>('id'),
                productLabel: r.read<String>('product_label'),
                unit: r.read<String>('unit'),
                quantity: r.read<int>('quantity'),
                fromLabel: r.read<String>('from_label'),
                toLabel: r.read<String>('to_label'),
                availableAtSource: r.read<int>('available'),
                movedAt: r.read<DateTime?>('moved_at'),
              ),
          ],
        );
  }

  // --- Gestes ---------------------------------------------------------------

  /// Une livraison fournisseur, a l'economat (ou dans un autre magasin).
  Future<String> receive({
    required String placeId,
    required String productId,
    required int quantity,
    int unitCost = 0,
    String? reason,
    String? by,
  }) async {
    if (quantity <= 0) throw StateError('La quantité doit être positive.');
    if (unitCost < 0) throw StateError('Le prix d’achat ne peut pas être négatif.');
    final id = newId();
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await _inserer(
        id: id,
        now: now,
        productId: productId,
        placeId: placeId,
        type: StockMovementType.IN,
        quantity: quantity,
        unitCost: unitCost,
        reason: reason,
        status: StockMovementStatus.APPROVED,
        by: by,
      );
      await _ajouter(productId, placeId, quantity, now);
      await enqueue(
        table: 'stock_movements',
        id: id,
        operation: SyncOp.INSERT,
        payload: {
          'id': id,
          'product_id': productId,
          'stock_location_id': placeId,
          'type': 'IN',
          'quantity': quantity,
          'unit_cost': unitCost,
          'reason': reason,
        },
      );
    });
    return id;
  }

  /// Demande de transfert d'un magasin a un autre. Rien ne bouge avant la
  /// validation.
  Future<String> requestTransfer({
    required String fromPlaceId,
    required String toPlaceId,
    required String productId,
    required int quantity,
    String? reason,
    String? by,
  }) async {
    // Les refus du serveur, faits ici : un refus par la file la bloquerait.
    if (quantity <= 0) throw StateError('La quantité doit être positive.');
    if (fromPlaceId == toPlaceId) {
      throw StateError('Un transfert va d’un magasin à un autre.');
    }
    final id = newId();
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await _inserer(
        id: id,
        now: now,
        productId: productId,
        placeId: fromPlaceId,
        counterpartId: toPlaceId,
        type: StockMovementType.TRANSFER,
        quantity: quantity,
        reason: reason,
        status: StockMovementStatus.PENDING,
        by: by,
      );
      await enqueue(
        table: 'stock_movements',
        id: id,
        operation: SyncOp.INSERT,
        payload: {
          'id': id,
          'product_id': productId,
          'stock_location_id': fromPlaceId,
          'counterpart_location_id': toPlaceId,
          'type': 'TRANSFER',
          'quantity': quantity,
          'reason': reason,
        },
      );
    });
    return id;
  }

  /// Valide un transfert : c'est maintenant que le stock bouge.
  Future<void> approve(String movementId, {String? note, String? by}) =>
      _decider(movementId, approuve: true, note: note, by: by);

  /// Refuse un transfert : rien ne bouge, le motif reste.
  Future<void> reject(String movementId, {String? note, String? by}) =>
      _decider(movementId, approuve: false, note: note, by: by);

  Future<void> _decider(
    String movementId, {
    required bool approuve,
    String? note,
    String? by,
  }) async {
    final m = await (db.select(
      db.stockMovements,
    )..where((x) => x.id.equals(movementId))).getSingle();
    // Le serveur refuse de valider un transfert refuse, et l'inverse.
    if (m.status != StockMovementStatus.PENDING) {
      throw StateError(
        m.status == StockMovementStatus.APPROVED
            ? 'Ce transfert a déjà été validé.'
            : 'Ce transfert a déjà été refusé.',
      );
    }
    final now = DateTime.now().toUtc();
    final motif = note?.trim();
    await db.transaction(() async {
      await (db.update(
        db.stockMovements,
      )..where((x) => x.id.equals(movementId))).write(
        StockMovementsCompanion(
          status: Value(
            approuve ? StockMovementStatus.APPROVED : StockMovementStatus.REJECTED,
          ),
          decidedBy: Value(by),
          decidedAt: Value(now),
          decisionNote: Value(motif == null || motif.isEmpty ? null : motif),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );
      if (approuve) {
        await _ajouter(m.productId, m.stockLocationId, -m.quantity, now);
        await _ajouter(m.productId, m.counterpartLocationId!, m.quantity, now);
      }
      // `action` : le statut seul ne dit pas quel endpoint appeler.
      await enqueue(
        table: 'stock_movements',
        id: movementId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': movementId,
          'action': approuve ? 'APPROVE' : 'REJECT',
          'note': motif == null || motif.isEmpty ? null : motif,
        },
      );
    });
  }

  /// Fait sortir du stock du point de vente ce qu'une ligne vendue consomme,
  /// comme le serveur le fera a la reception de la ligne.
  ///
  /// La sortie ne part pas dans la file : elle remonte avec sa ligne
  /// d'ardoise, que le serveur traduit lui-meme en mouvement. Elle est donc
  /// ecrite `synced` et rattachee a la ligne (`folio_items`), ce qui permet a
  /// la descente de la compter tant que la ligne n'est pas remontee.
  ///
  /// Rien si l'article n'est relie a aucun produit, ou si le point de vente
  /// n'a pas encore son magasin sur cette tablette. A appeler dans la
  /// transaction qui ecrit la ligne.
  Future<void> deductLocalForSale({
    required String outletId,
    required String menuItemId,
    required int quantity,
    required String folioItemId,
    String? by,
  }) async {
    if (quantity <= 0) return;
    final article = await (db.select(
      db.menuItems,
    )..where((a) => a.id.equals(menuItemId))).getSingleOrNull();
    final produit = article?.productId;
    if (article == null || produit == null) return;
    final magasin =
        await (db.select(db.stockLocations)
              ..where((m) => m.outletId.equals(outletId))
              ..limit(1))
            .getSingleOrNull();
    if (magasin == null) return;

    final now = DateTime.now().toUtc();
    final sortie = quantity * article.stockQuantity;
    await db
        .into(db.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: newId(),
            createdAt: now,
            updatedAt: now,
            hotelId: hotelId,
            productId: produit,
            stockLocationId: magasin.id,
            type: StockMovementType.OUT,
            quantity: sortie,
            reason: Value('Vente : ${article.label}'),
            sourceTable: const Value('folio_items'),
            sourceId: Value(folioItemId),
            movedAt: Value(now),
            movedBy: Value(by),
            status: const Value(StockMovementStatus.APPROVED),
            syncState: const Value(SyncState.synced),
          ),
        );
    await _ajouter(produit, magasin.id, -sortie, now);
  }

  Future<void> _inserer({
    required String id,
    required DateTime now,
    required String productId,
    required String placeId,
    required StockMovementType type,
    required int quantity,
    required StockMovementStatus status,
    String? counterpartId,
    int unitCost = 0,
    String? reason,
    String? by,
  }) => db
      .into(db.stockMovements)
      .insert(
        StockMovementsCompanion.insert(
          id: id,
          createdAt: now,
          updatedAt: now,
          hotelId: hotelId,
          productId: productId,
          stockLocationId: placeId,
          type: type,
          quantity: quantity,
          unitCost: Value(unitCost),
          reason: Value(reason),
          counterpartLocationId: Value(counterpartId),
          movedAt: Value(now),
          movedBy: Value(by),
          status: Value(status),
          syncState: const Value(SyncState.pending),
        ),
      );

  /// Ajoute (ou retire) au compteur d'un magasin, quitte a passer sous zero.
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
