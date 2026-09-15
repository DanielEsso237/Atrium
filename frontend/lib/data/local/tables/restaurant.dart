/// Restauration : points de vente, postes de preparation, menu, commandes.
library;

import 'package:drift/drift.dart';

import '../columns.dart';
import '../enums.dart';

/// Point de vente : restaurant, bar, piscine, room service (F3.1).
@DataClassName('OutletRow')
class Outlets extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get label => text().withLength(max: 80)();

  /// Heures au format HH:MM.
  TextColumn get opensAt => text().withLength(max: 5).nullable()();
  TextColumn get closesAt => text().withLength(max: 5).nullable()();

  BoolColumn get allowsRoomCharge =>
      boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Poste de preparation : cuisine, bar, patisserie.
///
/// Distinct du point de vente, parce que la relation n'est pas un a un : une
/// commande prise au bord de la piscine peut comporter des plats prepares en
/// cuisine et des boissons preparees au bar. C'est cette table qui porte la
/// regle R1 du cahier des charges.
@DataClassName('PrepStationRow')
class PrepStations extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get label => text().withLength(max: 80)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

@DataClassName('RestaurantTableRow')
class RestaurantTables extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get outletId => text().withLength(min: 36, max: 36)();
  TextColumn get number => text().withLength(max: 16)();
  IntColumn get capacity => integer().withDefault(const Constant(2))();
  TextColumn get zone => text().withLength(max: 64).nullable()();
  TextColumn get status =>
      textEnum<TableStatus>().withDefault(const Constant('FREE'))();
  IntColumn get mapX => integer().nullable()();
  IntColumn get mapY => integer().nullable()();
}

@DataClassName('MenuCategoryRow')
class MenuCategories extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get outletId => text().nullable()();
  TextColumn get label => text().withLength(max: 80)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get photoPath => text().withLength(max: 255).nullable()();
}

/// Article du menu (F3.5).
///
/// `prepStationId` est la colonne la plus importante de ce module. En
/// attachant le poste de preparation a l'article plutot qu'a la commande, la
/// regle R1 -- un ticket cuisine ne doit *jamais* partir au bar -- devient une
/// consequence du modele de donnees, et non une regle applicative qu'un
/// developpeur peut oublier dans six mois.
///
/// Une commande mixte se scinde alors d'elle-meme en un ticket cuisine et un
/// ticket bar, simplement parce que ses lignes pointent vers des postes
/// differents.
@DataClassName('MenuItemRow')
class MenuItems extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get label => text().withLength(max: 160)();
  TextColumn get description => text().nullable()();
  TextColumn get menuCategoryId => text().withLength(min: 36, max: 36)();
  /// Nul pour un article qui ne se prepare pas : droit d'entree en boite de
  /// nuit, acces piscine, bouteille vendue telle quelle. Une telle ligne ne
  /// produit aucun ticket de production, et le routage l'ignore.
  TextColumn get prepStationId => text().nullable()();

  /// Prix en francs CFA entiers, taux de taxe en points de base.
  IntColumn get price => integer().withDefault(const Constant(0))();
  IntColumn get taxRate => integer().withDefault(const Constant(0))();

  /// Rupture ponctuelle, distincte de `isActive` qui retire durablement
  /// l'article de la carte. Le serveur doit pouvoir signaler "plus de saumon
  /// ce soir" sans que le gerant ait a supprimer la ligne.
  BoolColumn get isAvailable => boolean().withDefault(const Constant(true))();
  IntColumn get preparationMinutes => integer().nullable()();

  /// Allergenes, en JSON.
  TextColumn get allergens => text().nullable()();
  TextColumn get photoPath => text().withLength(max: 255).nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Option ou variante : cuisson, accompagnement, supplement.
@DataClassName('MenuItemOptionRow')
class MenuItemOptions extends Table with SyncedTableColumns, RefTableColumns {
  TextColumn get menuItemId =>
      text().references(MenuItems, #id, onDelete: KeyAction.cascade)();
  TextColumn get groupLabel => text().withLength(max: 80).nullable()();
  TextColumn get label => text().withLength(max: 120)();

  /// Supplement de prix, en francs CFA, entiers. Peut etre negatif.
  IntColumn get priceDelta => integer().withDefault(const Constant(0))();
  BoolColumn get isRequired => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Commande (F3.1 a F3.6).
@DataClassName('OrderRow')
class Orders extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get number => text().withLength(max: 32)();
  TextColumn get outletId => text().withLength(min: 36, max: 36)();
  TextColumn get type =>
      textEnum<OrderType>().withDefault(const Constant('ON_SITE'))();
  TextColumn get status =>
      textEnum<OrderStatus>().withDefault(const Constant('DRAFT'))();

  TextColumn get restaurantTableId => text().nullable()();

  /// Room service : la commande vise une chambre et se reporte sur son folio.
  TextColumn get roomId => text().nullable()();
  TextColumn get folioId => text().nullable()();
  TextColumn get guestId => text().nullable()();
  TextColumn get waiterId => text().nullable()();

  IntColumn get covers => integer().withDefault(const Constant(1))();
  TextColumn get businessDate => text().withLength(max: 10).nullable()();

  DateTimeColumn get openedAt => dateTime().nullable()();

  /// Passage de DRAFT a SENT. C'est cet instant precis qui declenche
  /// l'emission des tickets vers les postes de preparation (F3.2) : tant que
  /// la commande est en brouillon, le serveur peut encore la corriger sans
  /// qu'un papier soit sorti en cuisine.
  DateTimeColumn get sentAt => dateTime().nullable()();
  DateTimeColumn get readyAt => dateTime().nullable()();
  DateTimeColumn get servedAt => dateTime().nullable()();
  DateTimeColumn get cancelledAt => dateTime().nullable()();
  TextColumn get cancelReason => text().withLength(max: 255).nullable()();

  /// Montants en francs CFA, entiers.
  IntColumn get subtotal => integer().withDefault(const Constant(0))();
  IntColumn get taxTotal => integer().withDefault(const Constant(0))();
  IntColumn get discountTotal => integer().withDefault(const Constant(0))();
  IntColumn get total => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
}

/// Ligne de commande.
///
/// `labelSnapshot`, `unitPrice` et `prepStationId` sont recopies depuis
/// l'article du menu au moment de la prise de commande. Cette duplication est
/// deliberee : une commande deja imprimee et facturee ne doit pas changer
/// retroactivement parce que le gerant a modifie un prix ou renomme un plat
/// une heure plus tard.
@DataClassName('OrderItemRow')
class OrderItems extends Table with SyncedTableColumns {
  TextColumn get orderId =>
      text().references(Orders, #id, onDelete: KeyAction.cascade)();
  TextColumn get menuItemId => text().nullable()();
  /// Nul pour un article qui ne se prepare pas : droit d'entree en boite de
  /// nuit, acces piscine, bouteille vendue telle quelle. Une telle ligne ne
  /// produit aucun ticket de production, et le routage l'ignore.
  TextColumn get prepStationId => text().nullable()();

  TextColumn get labelSnapshot => text().withLength(max: 160)();

  /// Quantite entiere, montants en francs CFA entiers.
  IntColumn get quantity => integer().withDefault(const Constant(1))();
  IntColumn get unitPrice => integer().withDefault(const Constant(0))();
  IntColumn get taxRate => integer().withDefault(const Constant(0))();
  IntColumn get amount => integer().withDefault(const Constant(0))();

  TextColumn get status =>
      textEnum<OrderStatus>().withDefault(const Constant('DRAFT'))();

  /// Instructions destinees au poste de preparation : "sans oignon",
  /// "bien cuit". Imprimees sur le ticket, pas seulement affichees.
  TextColumn get notes => text().withLength(max: 255).nullable()();
  DateTimeColumn get sentAt => dateTime().nullable()();
  DateTimeColumn get readyAt => dateTime().nullable()();
  BoolColumn get isVoid => boolean().withDefault(const Constant(false))();
  TextColumn get voidReason => text().withLength(max: 255).nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

@DataClassName('OrderItemOptionRow')
class OrderItemOptions extends Table with SyncedTableColumns {
  TextColumn get orderItemId =>
      text().references(OrderItems, #id, onDelete: KeyAction.cascade)();
  TextColumn get menuItemOptionId => text().nullable()();
  TextColumn get labelSnapshot => text().withLength(max: 120)();
  IntColumn get priceDelta => integer().withDefault(const Constant(0))();
}
