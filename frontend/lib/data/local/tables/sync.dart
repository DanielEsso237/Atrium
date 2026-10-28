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

  /// L'agent qui a fait l'ecriture : seule sa session la remonte.
  ///
  /// Une tablette passe de main en main, et le serveur juge une ecriture
  /// avec les droits du jeton qui l'envoie. Envoyee par le suivant,
  /// l'encaissement du receptionniste revenait refuse a l'agent du menage
  /// (403) et bloquait sa file (25 octobre). `null` pour les entrees sans
  /// session (code oublie, changement de PIN) : n'importe qui les remonte.
  TextColumn get authorId => text().nullable()();

  /// Ce que l'entree retient si le serveur la refuse, et ce qui la retient :
  /// son dossier, sa caisse, sa chambre… (`groupes_de_la_file.dart`).
  ///
  /// Un refus n'arrete plus toute la file, seulement ce qui partage une cle
  /// avec lui. `null` : on ne sait pas -- l'entree attend des que quoi que
  /// ce soit attend, comme avant le schema 20.
  TextColumn get groupKeys => text().nullable()();
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

/// Ce que cette tablette a annonce de ses propres blocages.
///
/// Une ligne par ecriture refusee (`outbox_entries` en `FAILED`). Le rapport
/// part hors de la file d'envoi -- elle est justement bloquee --, puis sa
/// levee quand l'ecriture passe ou quitte la file. Locale seulement : le
/// reflet que les autres postes lisent est `SyncBlocks`.
@DataClassName('BlockReportRow')
class BlockReports extends Table {
  /// L'id du rapport sur le serveur, tire ici : un renvoi ne fait pas
  /// doublon.
  TextColumn get id => text().withLength(min: 36, max: 36)();
  IntColumn get outboxEntryId => integer().unique()();
  DateTimeColumn get blockedAt => dateTime()();
  IntColumn get pendingBehind => integer().withDefault(const Constant(0))();

  /// Le rapport a change depuis son dernier envoi (ou n'est jamais parti).
  BoolColumn get aEnvoyer => boolean().withDefault(const Constant(true))();

  /// Le dernier envoi reussi ; nul tant que le serveur n'en sait rien.
  DateTimeColumn get reportedAt => dateTime().nullable()();

  /// Le blocage est leve : `SENT` ou `REMOVED`. Reste a le dire au serveur.
  TextColumn get resolution => text().withLength(max: 16).nullable()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();

  /// L'ecriture peut-elle s'abandonner a distance, et sinon pourquoi.
  /// Recalcule a chaque passage : une saisie qui arrive derriere peut en
  /// dependre (`abandon_ecriture.dart`).
  BoolColumn get abandonable => boolean().withDefault(const Constant(false))();
  TextColumn get abandonNote => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
