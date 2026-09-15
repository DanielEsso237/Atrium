/// Tables locales de synchronisation.
///
/// Elles n'existent que sur la tablette et ne sont jamais repliquees : ce sont
/// les tables de travail du moteur d'echange, pas des donnees metier.
///
/// Rien ne les alimente pour l'instant -- le moteur de synchronisation n'est
/// pas encore ecrit. Elles figurent ici parce qu'elles font partie de la
/// structure de la base locale, et que leur presence des la premiere version
/// du schema evite une migration sur des tablettes deja deployees le jour ou
/// la synchronisation sera branchee.
library;

import 'package:drift/drift.dart';

import '../enums.dart';

/// File d'attente des ecritures locales a pousser vers le serveur.
///
/// Toute modification faite sur la tablette y depose une ligne. L'ordre
/// d'insertion est l'ordre d'envoi : creer une reservation puis lui attribuer
/// une chambre doit arriver au serveur dans cet ordre, sinon la seconde
/// operation porte sur une ligne inexistante.
@DataClassName('OutboxEntryRow')
class OutboxEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entityTable => text().withLength(max: 64)();
  TextColumn get entityId => text().withLength(min: 36, max: 36)();
  TextColumn get op => textEnum<SyncOp>()();

  /// Etat complet de la ligne apres modification, en JSON.
  TextColumn get payload => text()();

  DateTimeColumn get createdAt => dateTime()();
  TextColumn get status =>
      textEnum<OutboxStatus>().withDefault(const Constant('PENDING'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().withLength(max: 512).nullable()();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
}

/// Position de la tablette dans l'ordre total des modifications du serveur,
/// table par table.
///
/// Un seul entier suffit : la tablette demande ce qui a change au-dela de ce
/// numero. `lastSeq` n'avance qu'apres l'ecriture effective des donnees
/// recues, pour qu'une coupure en cours de reception ne fasse pas sauter un
/// lot definitivement.
@DataClassName('SyncCursorRow')
class SyncCursors extends Table {
  TextColumn get entityTable => text().withLength(max: 64)();
  IntColumn get lastSeq => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastPullAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {entityTable};
}

/// Etat general de la synchronisation sur ce terminal.
///
/// Ligne unique. Alimente l'indicateur permanent que l'agent doit voir a
/// l'ecran : en mode kiosque, savoir si l'on travaille en ligne ou hors ligne
/// change la confiance que l'on accorde a ce qui est affiche.
@DataClassName('SyncStatusRow')
class SyncStatuses extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
  TextColumn get userId => text().nullable()();
  DateTimeColumn get lastFullSyncAt => dateTime().nullable()();
  DateTimeColumn get lastSuccessAt => dateTime().nullable()();
  BoolColumn get isOnline => boolean().withDefault(const Constant(false))();
  IntColumn get pendingCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().withLength(max: 512).nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// File de televersement des fichiers : photos de panne, signatures, scans.
///
/// Distincte de l'outbox parce que le rythme n'est pas le meme. Une ligne
/// metier pese quelques centaines d'octets et doit partir tout de suite ; une
/// photo pese quelques megaoctets et peut attendre un meilleur reseau. Les
/// melanger ferait retarder un ticket de maintenance urgent par la photo qui
/// l'accompagne.
@DataClassName('FileUploadRow')
class FileUploads extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entityTable => text().withLength(max: 64)();
  TextColumn get entityId => text().withLength(min: 36, max: 36)();
  TextColumn get localPath => text().withLength(max: 255)();
  TextColumn get mimeType => text().withLength(max: 80).nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  TextColumn get status =>
      textEnum<UploadState>().withDefault(const Constant('PENDING'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().withLength(max: 512).nullable()();
  TextColumn get remoteUrl => text().withLength(max: 512).nullable()();
  DateTimeColumn get createdAt => dateTime()();
}
