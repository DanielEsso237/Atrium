/// Parametrage, journee hoteliere, notifications.
library;

import 'package:drift/drift.dart';

import '../columns.dart';
import '../enums.dart';

/// Parametre applicatif.
///
/// La portee permet de surcharger un reglage global pour un terminal donne
/// (imprimante par defaut, delai de verrouillage) ou pour un agent, sans
/// dupliquer toute la configuration.
@DataClassName('SettingRow')
class Settings extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get key => text().withLength(max: 80)();

  /// Valeur en JSON, pour accepter indifferemment un nombre, un texte, un
  /// booleen ou une structure.
  TextColumn get value => text().nullable()();
  TextColumn get scope =>
      textEnum<SettingScope>().withDefault(const Constant('GLOBAL'))();
  TextColumn get scopeId => text().nullable()();
  TextColumn get label => text().withLength(max: 160).nullable()();
  TextColumn get description => text().nullable()();
}

/// Journee hoteliere et sa cloture.
///
/// La cloture fige les totaux plutot que de les laisser se recalculer : un
/// chiffre d'affaires arrete ne doit plus bouger, meme si une facture de la
/// veille est annulee le lendemain. C'est aussi ce qui rend les rapports du
/// module Direction (F5.2) reproductibles a l'identique.
@DataClassName('BusinessDayRow')
class BusinessDays extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get businessDate => text().withLength(max: 10)();
  TextColumn get status =>
      textEnum<BusinessDayStatus>().withDefault(const Constant('OPEN'))();
  DateTimeColumn get openedAt => dateTime().nullable()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  TextColumn get closedBy => text().nullable()();

  /// Totaux figes, en JSON : chiffre d'affaires hebergement et restauration,
  /// taxes, encaissements par mode de paiement, taux d'occupation, arrivees
  /// et departs.
  TextColumn get totals => text().nullable()();
  TextColumn get notes => text().nullable()();
}

/// Alerte destinee a un role ou a un agent.
///
/// Porte notamment les alertes de la regle R2 (imprimante hors ligne) et les
/// rejets d'attribution de chambre issus de l'arbitrage serveur -- deux cas ou
/// un humain doit etre prevenu tout de suite, sans quoi le probleme se
/// decouvre trop tard.
@DataClassName('NotificationRow')
class Notifications extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get kind => text().withLength(max: 48)();
  TextColumn get title => text().withLength(max: 160)();
  TextColumn get body => text().nullable()();
  TextColumn get severity =>
      text().withLength(max: 16).withDefault(const Constant('INFO'))();

  TextColumn get targetRoleId => text().nullable()();
  TextColumn get targetUserId => text().nullable()();
  TextColumn get entityTable => text().withLength(max: 64).nullable()();
  TextColumn get entityId => text().nullable()();

  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  DateTimeColumn get readAt => dateTime().nullable()();
  TextColumn get readBy => text().nullable()();
}
