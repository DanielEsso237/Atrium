/// Stocks : fournisseurs, produits, magasins, mouvements, inventaires.
library;

import 'package:drift/drift.dart';

import '../columns.dart';
import '../enums.dart';

@DataClassName('SupplierRow')
class Suppliers extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get name => text().withLength(max: 160)();
  TextColumn get contactName => text().withLength(max: 120).nullable()();
  TextColumn get phone => text().withLength(max: 40).nullable()();
  TextColumn get email => text().withLength(max: 160).nullable()();
  TextColumn get address => text().withLength(max: 255).nullable()();
  TextColumn get taxId => text().withLength(max: 40).nullable()();
  IntColumn get paymentTermsDays => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
}

@DataClassName('ProductCategoryRow')
class ProductCategories extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get label => text().withLength(max: 80)();
  TextColumn get parentId => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

@DataClassName('ProductRow')
class Products extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get reference => text().withLength(max: 32)();
  TextColumn get label => text().withLength(max: 160)();
  TextColumn get categoryId => text().nullable()();
  TextColumn get unit =>
      text().withLength(max: 16).withDefault(const Constant('U'))();
  TextColumn get barcode => text().withLength(max: 64).nullable()();

  /// Prix en francs CFA, entiers.
  IntColumn get purchasePrice => integer().withDefault(const Constant(0))();
  IntColumn get salePrice => integer().withDefault(const Constant(0))();

  /// Seuil d'alerte de reapprovisionnement, entier, dans l'unite du produit.
  IntColumn get minStock => integer().withDefault(const Constant(0))();

  /// Vendable directement au client (minibar), par opposition a un
  /// consommable interne (produit d'entretien).
  BoolColumn get isSellable => boolean().withDefault(const Constant(false))();
  TextColumn get defaultSupplierId => text().nullable()();
  TextColumn get notes => text().nullable()();
}

/// Magasin : economat, cuisine, bar, lingerie.
@DataClassName('StockLocationRow')
class StockLocations extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get label => text().withLength(max: 80)();
  TextColumn get managerId => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Quantite courante d'un produit dans un magasin.
///
/// Table maintenue, et non vue calculee : la tablette doit afficher un stock
/// hors ligne sans agreger tout l'historique des mouvements a chaque ouverture
/// d'ecran. [StockMovements] reste la source de verite -- ce compteur est
/// reconstruit par le serveur en cas de divergence.
@DataClassName('StockLevelRow')
class StockLevels extends Table with SyncedTableColumns {
  TextColumn get productId => text().withLength(min: 36, max: 36)();
  TextColumn get stockLocationId => text().withLength(min: 36, max: 36)();

  /// Quantite entiere, dans l'unite du produit.
  IntColumn get quantity => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastMovementAt => dateTime().nullable()();
}

/// Mouvement de stock : entree, sortie, transfert, ajustement, perte.
///
/// Journal en ajout seul. Un mouvement errone se corrige par un mouvement
/// inverse, jamais par une modification : c'est la seule facon de garder un
/// historique coherent quand plusieurs tablettes ecrivent hors ligne et se
/// synchronisent dans un ordre imprevisible.
@DataClassName('StockMovementRow')
class StockMovements extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get productId => text().withLength(min: 36, max: 36)();
  TextColumn get stockLocationId => text().withLength(min: 36, max: 36)();
  TextColumn get type => textEnum<StockMovementType>()();

  /// Quantite entiere, cout unitaire en francs CFA entiers.
  IntColumn get quantity => integer()();
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
  TextColumn get reason => text().withLength(max: 255).nullable()();

  /// Magasin de destination, pour un transfert.
  TextColumn get counterpartLocationId => text().nullable()();
  TextColumn get supplierId => text().nullable()();

  /// Origine du mouvement : consommation housekeeping, vente au minibar,
  /// casse. Permet de remonter du stock a l'operation qui l'a fait bouger.
  TextColumn get sourceTable => text().withLength(max: 64).nullable()();
  TextColumn get sourceId => text().nullable()();
  DateTimeColumn get movedAt => dateTime().nullable()();
  TextColumn get movedBy => text().nullable()();
}

@DataClassName('InventoryRow')
class Inventories extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get stockLocationId => text().withLength(min: 36, max: 36)();
  TextColumn get label => text().withLength(max: 120)();
  TextColumn get status =>
      textEnum<InventoryStatus>().withDefault(const Constant('DRAFT'))();
  TextColumn get inventoryDate => text().withLength(max: 10).nullable()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  TextColumn get closedBy => text().nullable()();
  TextColumn get notes => text().nullable()();
}

@DataClassName('InventoryLineRow')
class InventoryLines extends Table with SyncedTableColumns {
  TextColumn get inventoryId =>
      text().references(Inventories, #id, onDelete: KeyAction.cascade)();
  TextColumn get productId => text().withLength(min: 36, max: 36)();

  /// Quantite attendue, figee a l'ouverture de l'inventaire.
  ///
  /// La comparer a un stock theorique recalcule apres coup n'aurait aucun
  /// sens : le stock continue de bouger pendant le comptage.
  IntColumn get theoreticalQty => integer().withDefault(const Constant(0))();
  IntColumn get countedQty => integer().nullable()();
  IntColumn get variance => integer().withDefault(const Constant(0))();
  TextColumn get comment => text().withLength(max: 255).nullable()();
}
