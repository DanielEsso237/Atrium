/// Housekeeping, maintenance et pieces jointes du terrain.
library;

import 'package:drift/drift.dart';

import '../columns.dart';
import '../enums.dart';

/// Tache de nettoyage (F2.1, F2.2).
///
/// Les horodatages de debut et de fin ne servent pas qu'au suivi : ils
/// donnent la duree reelle par type de tache, seul moyen de dimensionner une
/// equipe d'etage et d'alimenter les indicateurs de performance du module
/// Direction (F5.1).
@DataClassName('HousekeepingTaskRow')
class HousekeepingTasks extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get roomId => text().withLength(min: 36, max: 36)();
  TextColumn get type => textEnum<HousekeepingTaskType>()();
  TextColumn get status =>
      textEnum<TaskStatus>().withDefault(const Constant('PENDING'))();
  TextColumn get priority =>
      textEnum<Priority>().withDefault(const Constant('NORMAL'))();
  TextColumn get businessDate => text().withLength(max: 10)();

  TextColumn get assignedTo => text().nullable()();
  DateTimeColumn get assignedAt => dateTime().nullable()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get finishedAt => dateTime().nullable()();
  IntColumn get durationMinutes => integer().nullable()();

  TextColumn get inspectedBy => text().nullable()();
  DateTimeColumn get inspectedAt => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
}

/// Point de controle d'une fiche de tache, telle qu'imprimee en F2.5.
@DataClassName('HousekeepingTaskItemRow')
class HousekeepingTaskItems extends Table with SyncedTableColumns {
  TextColumn get taskId =>
      text().references(HousekeepingTasks, #id, onDelete: KeyAction.cascade)();
  TextColumn get label => text().withLength(max: 160)();
  BoolColumn get isDone => boolean().withDefault(const Constant(false))();
  TextColumn get remark => text().withLength(max: 255).nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Consommables et linge utilises sur une tache (F2.4).
///
/// Fait le pont entre le housekeeping et les stocks : chaque ligne donnera un
/// mouvement de sortie sur le magasin de l'etage.
@DataClassName('AmenityConsumptionRow')
class AmenityConsumptions extends Table with SyncedTableColumns {
  TextColumn get taskId =>
      text().references(HousekeepingTasks, #id, onDelete: KeyAction.cascade)();
  TextColumn get productId => text().withLength(min: 36, max: 36)();

  /// Quantite entiere. L'unite est portee par le produit (`products.unit`).
  IntColumn get quantity => integer().withDefault(const Constant(1))();
}

/// Equipement suivi : climatiseur, chauffe-eau, televiseur, ascenseur.
///
/// Permet l'historique par equipement demande en F4.4, qui ne se deduit pas de
/// l'historique par chambre : un climatiseur peut etre deplace d'une chambre a
/// une autre, et un ascenseur n'appartient a aucune chambre.
@DataClassName('EquipmentRow')
class Equipments extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get label => text().withLength(max: 160)();
  TextColumn get category => text().withLength(max: 64).nullable()();
  TextColumn get roomId => text().nullable()();
  TextColumn get location => text().withLength(max: 120).nullable()();
  TextColumn get brand => text().withLength(max: 80).nullable()();
  TextColumn get model => text().withLength(max: 80).nullable()();
  TextColumn get serialNumber => text().withLength(max: 80).nullable()();
  TextColumn get installedAt => text().withLength(max: 10).nullable()();
  TextColumn get warrantyUntil => text().withLength(max: 10).nullable()();
  TextColumn get supplierId => text().nullable()();
}

/// Signalement et intervention (F2.3, F4.1 a F4.4).
///
/// `blocksRoom` fait le lien avec `Rooms.isOutOfOrder` : ouvrir un ticket
/// bloquant sort la chambre de la vente, le cloturer l'y remet. Sans ce lien
/// explicite, une chambre reste hors service parce que personne ne pense a
/// rebasculer le drapeau une fois la reparation faite -- et l'hotel perd des
/// nuitees sans s'en apercevoir.
@DataClassName('MaintenanceTicketRow')
class MaintenanceTickets extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get number => text().withLength(max: 32)();
  TextColumn get roomId => text().nullable()();
  TextColumn get equipmentId => text().nullable()();
  TextColumn get location => text().withLength(max: 120).nullable()();
  TextColumn get category => text().withLength(max: 64).nullable()();

  TextColumn get title => text().withLength(max: 160)();
  TextColumn get description => text().nullable()();
  TextColumn get priority =>
      textEnum<Priority>().withDefault(const Constant('NORMAL'))();
  TextColumn get status =>
      textEnum<TicketStatus>().withDefault(const Constant('OPEN'))();

  TextColumn get reportedBy => text().nullable()();
  DateTimeColumn get reportedAt => dateTime().nullable()();
  TextColumn get assignedTo => text().nullable()();
  DateTimeColumn get assignedAt => dateTime().nullable()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  TextColumn get resolution => text().nullable()();

  /// Cout en francs CFA, entiers.
  IntColumn get cost => integer().withDefault(const Constant(0))();
  BoolColumn get blocksRoom => boolean().withDefault(const Constant(false))();
}

/// Passage d'un technicien sur un ticket.
///
/// Un ticket demande souvent plusieurs passages : diagnostic, commande de
/// piece, reparation. Les tracer separement donne le temps reellement passe et
/// le cout des pieces, que le seul ticket ne permet pas de reconstituer.
@DataClassName('MaintenanceInterventionRow')
class MaintenanceInterventions extends Table with SyncedTableColumns {
  TextColumn get ticketId =>
      text().references(MaintenanceTickets, #id, onDelete: KeyAction.cascade)();
  TextColumn get technicianId => text().nullable()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  TextColumn get description => text().nullable()();

  /// Pieces utilisees, en JSON.
  TextColumn get partsUsed => text().nullable()();
  IntColumn get cost => integer().withDefault(const Constant(0))();
}

/// Piece jointe generique : photo de panne, document, rapport.
///
/// Meme principe que les signatures : le fichier existe d'abord sur la
/// tablette, puis recoit une URL serveur. Le televersement est suivi
/// separement de la synchronisation des lignes metier, parce qu'une photo de
/// trois megaoctets prise dans un couloir sans reseau ne doit pas retarder la
/// remontee du ticket urgent auquel elle est attachee, qui ne pese lui que
/// quelques centaines d'octets.
@DataClassName('AttachmentRow')
class Attachments extends Table with SyncedTableColumns {
  TextColumn get entityTable => text().withLength(max: 64)();
  TextColumn get entityId => text().withLength(min: 36, max: 36)();
  TextColumn get kind =>
      text().withLength(max: 32).withDefault(const Constant('PHOTO'))();
  TextColumn get filePathLocal => text().withLength(max: 255).nullable()();
  TextColumn get fileUrl => text().withLength(max: 512).nullable()();
  TextColumn get mimeType => text().withLength(max: 80).nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  TextColumn get uploadState =>
      textEnum<UploadState>().withDefault(const Constant('PENDING'))();
  TextColumn get caption => text().withLength(max: 255).nullable()();
  DateTimeColumn get capturedAt => dateTime().nullable()();
  TextColumn get capturedBy => text().nullable()();
}
