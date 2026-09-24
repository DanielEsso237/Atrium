/// Socle : etablissement, utilisateurs, roles, permissions, terminal.
library;

import 'package:drift/drift.dart';

import '../columns.dart';

@DataClassName('HotelRow')
class Hotels extends Table with SyncedTableColumns {
  TextColumn get code => text().withLength(max: 16)();
  TextColumn get name => text().withLength(max: 160)();
  TextColumn get legalName => text().withLength(max: 160).nullable()();
  TextColumn get address => text().withLength(max: 255).nullable()();
  TextColumn get city => text().withLength(max: 80).nullable()();
  TextColumn get postalCode => text().withLength(max: 20).nullable()();
  TextColumn get country => text().withLength(max: 80).nullable()();
  TextColumn get phone => text().withLength(max: 40).nullable()();
  TextColumn get email => text().withLength(max: 160).nullable()();
  TextColumn get website => text().withLength(max: 160).nullable()();
  TextColumn get taxId => text().withLength(max: 40).nullable()();
  TextColumn get logoPath => text().withLength(max: 255).nullable()();
  TextColumn get timezone => text()
      .withLength(max: 64)
      .withDefault(const Constant('Africa/Abidjan'))();
  TextColumn get currency =>
      text().withLength(max: 8).withDefault(const Constant('XOF'))();

  /// Heure de bascule de la journee hoteliere.
  ///
  /// Le chiffre d'affaires du jour ne se calcule pas de minuit a minuit : une
  /// addition servie au bar a 1 h du matin appartient a la journee de la
  /// veille. Sans ce reglage, le tableau de bord du paragraphe 5.1 affiche des
  /// chiffres que la direction ne reconnait pas.
  IntColumn get dayRolloverHour => integer().withDefault(const Constant(6))();

  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

@DataClassName('RoleRow')
class Roles extends Table with SyncedTableColumns, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get label => text().withLength(max: 80)();
  TextColumn get description => text().nullable()();
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();

  /// Ecran d'accueil apres connexion.
  ///
  /// Le cahier des charges (paragraphe 3.4) prevoit une seule application dont
  /// l'interface change selon le role : une gouvernante et un receptionniste
  /// ouvrent la meme application mais n'arrivent pas sur le meme ecran.
  TextColumn get homeRoute => text().withLength(max: 80).nullable()();
}

@DataClassName('PermissionRow')
class Permissions extends Table with BaseColumns {
  TextColumn get code => text().withLength(max: 64)();
  TextColumn get label => text().withLength(max: 120)();
  TextColumn get module => text().withLength(max: 32)();
}

@DataClassName('RolePermissionRow')
class RolePermissions extends Table {
  TextColumn get roleId =>
      text().references(Roles, #id, onDelete: KeyAction.cascade)();
  TextColumn get permissionId =>
      text().references(Permissions, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {roleId, permissionId};
}

@DataClassName('UserRow')
class Users extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get employeeCode => text().withLength(max: 32)();
  TextColumn get firstName => text().withLength(max: 80)();
  TextColumn get lastName => text().withLength(max: 80)();
  TextColumn get email => text().withLength(max: 160).nullable()();
  TextColumn get phone => text().withLength(max: 40).nullable()();
  TextColumn get photoPath => text().withLength(max: 255).nullable()();

  /// Trois voies d'authentification, toutes hachees (exigence 6.2).
  ///
  /// Le code PIN n'est pas un mot de passe au rabais : c'est ce qui rend
  /// utilisable une tablette en mode kiosque, ou dix agents se succedent sur
  /// le meme terminal dans un service. Le badge sert aux equipes de terrain,
  /// qui ne peuvent pas saisir un mot de passe les mains occupees.
  ///
  /// Les empreintes sont repliquees sur la tablette : sans elles, plus aucune
  /// connexion ne serait possible pendant une coupure reseau, ce qui viderait
  /// de son sens tout le mode hors ligne.
  TextColumn get passwordHash => text().withLength(max: 255).nullable()();
  TextColumn get pinHash => text().withLength(max: 255).nullable()();
  TextColumn get badgeCode => text().withLength(max: 64).nullable()();

  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BoolColumn get mustChangePassword =>
      boolean().withDefault(const Constant(true))();
  DateTimeColumn get lastLoginAt => dateTime().nullable()();
  IntColumn get failedLoginCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get lockedUntil => dateTime().nullable()();
  TextColumn get language =>
      text().withLength(max: 8).withDefault(const Constant('fr'))();
}

@DataClassName('UserRoleRow')
class UserRoles extends Table {
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get roleId =>
      text().references(Roles, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {userId, roleId};
}

/// Terminaux connus.
///
/// La tablette porte la flotte entiere et pas seulement sa propre fiche : la
/// reception doit pouvoir constater qu'une tablette du restaurant n'a plus
/// synchronise depuis deux heures sans ouvrir l'interface d'administration.
@DataClassName('DeviceRow')
class Devices extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get deviceUid => text().withLength(max: 128)();
  TextColumn get name => text().withLength(max: 80)();
  TextColumn get location => text().withLength(max: 120).nullable()();

  TextColumn get defaultRoleId => text().nullable()();
  TextColumn get defaultOutletId => text().nullable()();

  /// Imprimante de repli du terminal, quand aucune regle de routage plus
  /// precise ne s'applique.
  TextColumn get defaultPrinterId => text().nullable()();

  BoolColumn get isKiosk => boolean().withDefault(const Constant(true))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get osVersion => text().withLength(max: 40).nullable()();
  TextColumn get appVersion => text().withLength(max: 20).nullable()();
  DateTimeColumn get lastSeenAt => dateTime().nullable()();
  DateTimeColumn get lastSyncAt => dateTime().nullable()();

  /// Verrouillage automatique apres inactivite (exigence 6.2). Une tablette
  /// posee sur le comptoir de la reception ne doit pas rester ouverte.
  IntColumn get autoLockSeconds => integer().withDefault(const Constant(300))();
}
