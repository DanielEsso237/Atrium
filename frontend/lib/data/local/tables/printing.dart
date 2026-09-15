/// Impression localisee : imprimantes, routage, modeles, file d'attente.
///
/// C'est le coeur du projet (paragraphe 4.2 du cahier des charges). Les cinq
/// regles de routage y sont traduites en structures de donnees :
///
///   R1  cuisine != bar        -> `OrderItems.prepStationId` -> `PrintRoutes`
///   R2  hors ligne -> file    -> `PrintJobs.status` + `Printers.isOnline`
///   R3  reimpression          -> `PrintJobs.isDuplicate` + `originalJobId`
///   R4  nom logique           -> `Printers.logicalName`
///   R5  routage configurable  -> `PrintRoutes`, editable a l'administration
library;

import 'package:drift/drift.dart';

import '../columns.dart';
import '../enums.dart';

/// Imprimante physique, designee par un nom logique (regle R4).
///
/// L'application ne manipule jamais une adresse IP : elle demande
/// `IMP_CUISINE_01`. Remplacer une imprimante en panne revient alors a changer
/// une ligne de configuration, sans toucher au code ni redeployer les
/// tablettes.
@DataClassName('PrinterRow')
class Printers extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get logicalName => text().withLength(max: 64)();
  TextColumn get label => text().withLength(max: 120)();
  TextColumn get kind => textEnum<PrinterKind>()();
  TextColumn get protocol => textEnum<PrinterProtocol>()();
  TextColumn get host => text().withLength(max: 120).nullable()();
  IntColumn get port => integer().nullable()();
  TextColumn get devicePath => text().withLength(max: 255).nullable()();

  /// Largeur du papier thermique en millimetres : 58 ou 80 en pratique.
  /// Determine le nombre de caracteres par ligne du modele ESC/POS.
  IntColumn get paperWidthMm => integer().nullable()();
  TextColumn get location => text().withLength(max: 120).nullable()();
  TextColumn get prepStationId => text().nullable()();

  /// Supervision (regle R2). Sans battement de coeur, on ne decouvre qu'une
  /// imprimante est hors ligne qu'au moment ou un ticket est deja perdu et ou
  /// la cuisine attend une commande dont elle ignore l'existence.
  BoolColumn get isOnline => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastHeartbeatAt => dateTime().nullable()();
  TextColumn get lastError => text().withLength(max: 255).nullable()();

  /// Repli automatique quand la cible est injoignable.
  TextColumn get fallbackPrinterId => text().nullable()();
}

/// Nature de document imprimable, reprise de la matrice du paragraphe 4.2.
@DataClassName('DocumentTypeRow')
class DocumentTypes extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 48)();
  TextColumn get label => text().withLength(max: 120)();
  TextColumn get defaultKind =>
      textEnum<PrinterKind>().withDefault(const Constant('LASER'))();

  /// Nombre d'exemplaires par defaut : souche et client.
  IntColumn get copies => integer().withDefault(const Constant(1))();
  BoolColumn get allowReprint => boolean().withDefault(const Constant(true))();
}

/// Regle de routage (regle R5).
///
/// Resolution : parmi les regles actives du type de document, on retient celle
/// de plus forte priorite dont tous les criteres renseignes correspondent au
/// contexte. Un critere laisse nul est un joker.
///
/// La table est editable depuis l'administration, ce qui evite de livrer une
/// nouvelle version de l'application chaque fois que l'hotel deplace une
/// imprimante ou ouvre un point de vente.
@DataClassName('PrintRouteRow')
class PrintRoutes extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get documentTypeId => text().withLength(min: 36, max: 36)();
  TextColumn get printerId => text().withLength(min: 36, max: 36)();

  TextColumn get matchOutletId => text().nullable()();
  TextColumn get matchPrepStationId => text().nullable()();
  TextColumn get matchDeviceId => text().nullable()();
  TextColumn get matchRoleId => text().nullable()();

  /// Priorite decroissante : la premiere regle qui correspond l'emporte.
  IntColumn get priority => integer().withDefault(const Constant(0))();
  TextColumn get label => text().withLength(max: 120).nullable()();
}

/// Modele de document, versionne.
///
/// Le versionnage sert la reimpression : reproduire une facture de l'an
/// dernier doit donner la mise en page de l'epoque, pas celle d'aujourd'hui.
@DataClassName('DocumentTemplateRow')
class DocumentTemplates extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get documentTypeId => text().withLength(min: 36, max: 36)();
  IntColumn get version => integer().withDefault(const Constant(1))();
  TextColumn get format => textEnum<TemplateFormat>()();
  TextColumn get content => text()();
  TextColumn get label => text().withLength(max: 120).nullable()();
}

/// Travail d'impression, du declenchement a la sortie papier.
///
/// Cette table est le coeur de la file d'attente exigee au paragraphe 6.3. Un
/// ticket cree pendant une coupure Wi-Fi est enregistre localement en QUEUED
/// et part a la reconnexion : il n'est jamais perdu.
///
/// `payload` conserve les donnees du document plutot qu'une simple reference a
/// la commande. Un ticket de cuisine doit pouvoir etre reimprime a l'identique
/// meme si la commande a ete modifiee depuis -- sinon la reimpression d'un
/// duplicata montrerait autre chose que l'original.
@DataClassName('PrintJobRow')
class PrintJobs extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get documentTypeId => text().withLength(min: 36, max: 36)();
  TextColumn get printerId => text().nullable()();
  TextColumn get templateId => text().nullable()();

  /// Donnees du document, en JSON.
  TextColumn get payload => text().nullable()();

  /// Document deja mis en forme : flux ESC/POS ou PDF.
  BlobColumn get rendered => blob().nullable()();

  TextColumn get status =>
      textEnum<PrintJobStatus>().withDefault(const Constant('QUEUED'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().withLength(max: 255).nullable()();

  /// Regle R3 : une reimpression est un nouveau travail marque DUPLICATA et
  /// relie a l'original, jamais une reexecution silencieuse du premier. Cela
  /// evite qu'un ticket ressorte deux fois en cuisine sans que personne ne
  /// puisse dire lequel est le bon.
  BoolColumn get isDuplicate => boolean().withDefault(const Constant(false))();
  TextColumn get originalJobId => text().nullable()();

  TextColumn get sourceTable => text().withLength(max: 64).nullable()();
  TextColumn get sourceId => text().nullable()();
  TextColumn get requestedBy => text().nullable()();
  TextColumn get requestedFromDeviceId => text().nullable()();
  DateTimeColumn get sentAt => dateTime().nullable()();
  DateTimeColumn get printedAt => dateTime().nullable()();
}
