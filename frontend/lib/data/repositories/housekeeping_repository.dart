/// Le menage des chambres (cahier des charges, F2.1-F2.2).
///
/// Trois etats, et rien de plus : une chambre est a faire, en cours, ou
/// faite. La femme de chambre travaille debout, souvent d'une main, parfois
/// dans un couloir sans reseau -- c'est le module ou la simplicite compte le
/// plus.
///
/// Le statut vit a deux endroits, volontairement. La **tache** garde
/// l'histoire : qui a nettoye, quand, combien de temps, ce qui servira a
/// dimensionner les equipes. La **chambre** porte l'etat courant, parce que
/// c'est lui que le plan de la reception affiche, et qu'aller le chercher
/// dans la derniere tache de chaque chambre a chaque rafraichissement d'ecran
/// serait absurde.
///
/// Les deux bougent ensemble, dans la meme transaction. Le serveur fait
/// exactement pareil de son cote.
library;

import 'package:drift/drift.dart';

import '../../core/formats.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// Une chambre a faire, telle que la femme de chambre la voit.
class CleaningJob {
  const CleaningJob({
    required this.taskId,
    required this.roomId,
    required this.roomNumber,
    required this.floorLabel,
    required this.status,
    required this.type,
    required this.priority,
    this.startedAt,
    this.durationMinutes,
  });

  final String taskId;
  final String roomId;
  final String roomNumber;
  final String floorLabel;
  final TaskStatus status;
  final HousekeepingTaskType type;
  final Priority priority;
  final DateTime? startedAt;
  final int? durationMinutes;

  bool get enCours => status == TaskStatus.IN_PROGRESS;
  bool get faite => status == TaskStatus.DONE || status == TaskStatus.INSPECTED;

  /// Depuis combien de minutes le menage a commence.
  int? get minutesEcoulees {
    if (startedAt == null || !enCours) return null;
    return DateTime.now().toUtc().difference(startedAt!).inMinutes;
  }
}

class HousekeepingRepository with OutboxWriter {
  HousekeepingRepository(this.db);

  @override
  final AtriumDatabase db;

  static const hotelId = '01920000-0000-7000-8000-000000000001';

  /// Les chambres a faire aujourd'hui, les urgentes d'abord.
  ///
  /// Les taches terminees restent affichees jusqu'au changement de journee :
  /// une femme de chambre qui vient de finir la 201 doit la voir barree, pas
  /// la voir disparaitre -- sinon elle se demande si son geste a ete pris en
  /// compte.
  Stream<List<CleaningJob>> watchJobs() {
    return db
        .customSelect(
          '''
          SELECT t.id            AS task_id,
                 t.room_id       AS room_id,
                 t.status        AS status,
                 t.type          AS type,
                 t.priority      AS priority,
                 t.started_at    AS started_at,
                 t.duration_minutes AS duration_minutes,
                 r.number        AS room_number,
                 COALESCE(f.label, '') AS floor_label
            FROM housekeeping_tasks t
            JOIN rooms r  ON r.id = t.room_id
       LEFT JOIN floors f ON f.id = r.floor_id
           WHERE t.deleted_at IS NULL
             AND t.status <> 'CANCELLED'
        ORDER BY CASE t.status
                   WHEN 'IN_PROGRESS' THEN 0
                   WHEN 'PENDING'     THEN 1
                   WHEN 'ASSIGNED'    THEN 1
                   ELSE 2
                 END,
                 CASE t.priority
                   WHEN 'URGENT' THEN 0
                   WHEN 'HIGH'   THEN 1
                   WHEN 'NORMAL' THEN 2
                   ELSE 3
                 END,
                 r.number
          ''',
          readsFrom: {db.housekeepingTasks, db.rooms, db.floors},
        )
        .watch()
        .map(
          (lignes) => lignes
              .map(
                (l) => CleaningJob(
                  taskId: l.read<String>('task_id'),
                  roomId: l.read<String>('room_id'),
                  roomNumber: l.read<String>('room_number'),
                  floorLabel: l.read<String>('floor_label'),
                  status: TaskStatus.values.byName(l.read<String>('status')),
                  type: HousekeepingTaskType.values.byName(
                    l.read<String>('type'),
                  ),
                  priority: Priority.values.byName(l.read<String>('priority')),
                  startedAt: l.read<DateTime?>('started_at'),
                  durationMinutes: l.read<int?>('duration_minutes'),
                ),
              )
              .toList(),
        );
  }

  /// Ouvre une tache de menage sur une chambre.
  ///
  /// Appelee au depart d'un client. Idempotente sur la journee : deux departs
  /// enregistres coup sur coup, ou un ecran rejoue, ne doivent pas faire
  /// apparaitre deux fois la meme chambre dans la liste -- la femme de
  /// chambre y verrait une erreur, et le second passage serait compte comme
  /// du travail fait.
  ///
  /// Renvoie l'identifiant de la tache, existante ou nouvelle.
  Future<String> openTask({
    required String roomId,
    HousekeepingTaskType type = HousekeepingTaskType.DEPARTURE,
    Priority priority = Priority.NORMAL,
    String? by,
  }) async {
    final businessDate = formatIsoDate(DateTime.now());

    final existante =
        await (db.select(db.housekeepingTasks)..where(
              (t) =>
                  t.roomId.equals(roomId) &
                  t.businessDate.equals(businessDate) &
                  t.deletedAt.isNull() &
                  t.status.isNotInValues([
                    TaskStatus.DONE,
                    TaskStatus.INSPECTED,
                    TaskStatus.CANCELLED,
                  ]),
            ))
            .getSingleOrNull();
    if (existante != null) return existante.id;

    final id = newId();
    final now = DateTime.now().toUtc();

    await writeAndEnqueue(
      table: 'housekeeping_tasks',
      id: id,
      operation: SyncOp.INSERT,
      payload: {
        'id': id,
        'room_id': roomId,
        'type': type.name,
        'priority': priority.name,
        'business_date': businessDate,
      },
      action: () => db
          .into(db.housekeepingTasks)
          .insert(
            HousekeepingTasksCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              roomId: roomId,
              type: type,
              status: const Value(TaskStatus.PENDING),
              priority: Value(priority),
              businessDate: businessDate,
              createdBy: Value(by),
              syncState: const Value(SyncState.pending),
            ),
          ),
    );

    return id;
  }

  /// La femme de chambre commence : la chambre passe en nettoyage.
  ///
  /// La reception le voit aussitot sur son plan -- c'est tout l'interet
  /// d'avoir trois etats plutot que deux. Une chambre en cours de nettoyage
  /// n'est ni sale ni attribuable.
  Future<void> start(String taskId, {String? by}) =>
      _transition(taskId, TaskStatus.IN_PROGRESS, by: by);

  /// La femme de chambre a fini : la chambre redevient disponible.
  Future<void> finish(String taskId, {String? by}) =>
      _transition(taskId, TaskStatus.DONE, by: by);

  Future<void> _transition(
    String taskId,
    TaskStatus vers, {
    String? by,
  }) async {
    final tache = await (db.select(
      db.housekeepingTasks,
    )..where((t) => t.id.equals(taskId))).getSingleOrNull();

    if (tache == null) throw StateError('Tache introuvable.');
    if (tache.status == vers) return; // deja fait, rien a refaire

    final now = DateTime.now().toUtc();
    final demarre = vers == TaskStatus.IN_PROGRESS;

    if (!demarre && tache.status != TaskStatus.IN_PROGRESS) {
      throw StateError(
        'Il faut commencer le menage avant de le terminer.',
      );
    }

    await db.transaction(() async {
      await (db.update(
        db.housekeepingTasks,
      )..where((t) => t.id.equals(taskId))).write(
        HousekeepingTasksCompanion(
          status: Value(vers),
          startedAt: demarre ? Value(now) : const Value.absent(),
          finishedAt: demarre ? const Value.absent() : Value(now),
          // Calculee localement pour que l'ecran l'affiche sans attendre le
          // serveur ; il la recalculera de son cote, et c'est la sienne qui
          // fera foi.
          durationMinutes: demarre || tache.startedAt == null
              ? const Value.absent()
              : Value(now.difference(tache.startedAt!).inMinutes),
          assignedTo: Value(by),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      await (db.update(
        db.rooms,
      )..where((r) => r.id.equals(tache.roomId))).write(
        RoomsCompanion(
          housekeepingStatus: Value(
            demarre ? HousekeepingStatus.IN_PROGRESS : HousekeepingStatus.CLEAN,
          ),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      // Le verbe part dans la file, pas l'etat : le serveur a un endpoint par
      // transition (`/start`, `/finish`) et calcule lui-meme les horodatages.
      await enqueue(
        table: 'housekeeping_tasks',
        id: taskId,
        operation: SyncOp.UPDATE,
        payload: {'id': taskId, 'status': vers.name},
      );
    });
  }
}
