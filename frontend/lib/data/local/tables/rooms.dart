/// Hebergement : etages, types de chambres, chambres, tarifs, taxes.
library;

import 'package:drift/drift.dart';

import '../columns.dart';
import '../enums.dart';

@DataClassName('FloorRow')
class Floors extends Table with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 16)();
  TextColumn get label => text().withLength(max: 80)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Fond de plan de l'etage, pour l'ecran graphique du paragraphe 5.2.
  TextColumn get mapImagePath => text().withLength(max: 255).nullable()();
}

@DataClassName('RoomTypeRow')
class RoomTypes extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 16)();
  TextColumn get label => text().withLength(max: 80)();
  TextColumn get description => text().nullable()();
  IntColumn get baseCapacity => integer().withDefault(const Constant(2))();
  IntColumn get maxCapacity => integer().withDefault(const Constant(2))();

  /// Tarif de reference, en francs CFA, entiers.
  IntColumn get defaultRate => integer().withDefault(const Constant(0))();

  /// Equipements, en JSON. Chaque etablissement suit sa propre liste et la
  /// fait evoluer : un schema fige imposerait une migration a chaque ajout.
  TextColumn get amenities => text().nullable()();
  TextColumn get photoPath => text().withLength(max: 255).nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Chambre physique.
///
/// Le point de modelisation le plus important du module. Le cahier des charges
/// (paragraphe 5.2) affiche un etat unique par pastille de couleur :
/// disponible, occupee, reservee, nettoyage, maintenance. C'est le bon
/// affichage, mais ce serait un mauvais stockage, parce que ces valeurs ne
/// s'excluent pas : une chambre peut etre occupee *et* en cours de nettoyage,
/// ou en maintenance *et* sale.
///
/// On conserve donc trois axes independants, et la pastille est calculee a
/// l'affichage. Si l'on n'avait qu'une colonne, la reception et le
/// housekeeping ecriraient la meme case pour deux raisons differentes et
/// s'ecraseraient mutuellement a chaque synchronisation -- exactement le genre
/// de perte de donnee que le mode hors ligne rend inevitable.
///
/// Ces colonnes sont materialisees plutot que deduites des reservations : le
/// plan de l'hotel doit s'afficher instantanement et hors ligne, sans croiser
/// des intervalles de dates sur toute la table des sejours.
@DataClassName('RoomRow')
class Rooms extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get number => text().withLength(max: 16)();
  TextColumn get roomTypeId => text().withLength(min: 36, max: 36)();
  TextColumn get floorId => text().nullable()();

  TextColumn get occupancyStatus => textEnum<OccupancyStatus>()
      .withDefault(const Constant('VACANT'))();
  TextColumn get housekeepingStatus => textEnum<HousekeepingStatus>()
      .withDefault(const Constant('CLEAN'))();

  BoolColumn get isOutOfOrder => boolean().withDefault(const Constant(false))();
  TextColumn get outOfOrderReason => text().withLength(max: 255).nullable()();

  /// Date au format AAAA-MM-JJ.
  TextColumn get outOfOrderUntil => text().withLength(max: 10).nullable()();

  /// Position sur le plan interactif (F1.7).
  IntColumn get mapX => integer().nullable()();
  IntColumn get mapY => integer().nullable()();

  TextColumn get phoneExt => text().withLength(max: 16).nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

@DataClassName('RatePlanRow')
class RatePlans extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get label => text().withLength(max: 120)();
  TextColumn get roomTypeId => text().nullable()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  TextColumn get validFrom => text().withLength(max: 10).nullable()();
  TextColumn get validTo => text().withLength(max: 10).nullable()();
  IntColumn get minNights => integer().withDefault(const Constant(1))();
  BoolColumn get includesBreakfast =>
      boolean().withDefault(const Constant(false))();
  TextColumn get description => text().nullable()();
}

@DataClassName('RatePlanPriceRow')
class RatePlanPrices extends Table with SyncedTableColumns {
  TextColumn get ratePlanId =>
      text().references(RatePlans, #id, onDelete: KeyAction.cascade)();
  TextColumn get dateFrom => text().withLength(max: 10)();
  TextColumn get dateTo => text().withLength(max: 10)();

  /// Masque binaire des jours concernes : bit 0 = lundi, bit 6 = dimanche.
  /// 127 couvre toute la semaine. Permet un tarif de week-end distinct sans
  /// dupliquer une ligne par date.
  IntColumn get weekdayMask => integer().withDefault(const Constant(127))();

  /// Prix en francs CFA, entiers.
  IntColumn get price => integer().withDefault(const Constant(0))();
}

@DataClassName('TaxRow')
class Taxes extends Table with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get label => text().withLength(max: 120)();
  TextColumn get mode => textEnum<TaxMode>()();

  /// Taux en points de base pour le mode PERCENT (18 % vaut 1800), montant en
  /// francs CFA entiers pour les modes forfaitaires.
  IntColumn get rate => integer().withDefault(const Constant(0))();

  /// Categories de charges concernees, en JSON.
  TextColumn get appliesTo => text().nullable()();

  /// Taxe comprise dans le prix affiche, ou ajoutee au moment de la
  /// facturation. Ce drapeau change entierement le calcul de la facture, il ne
  /// peut pas etre une convention implicite.
  BoolColumn get isIncluded => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}
