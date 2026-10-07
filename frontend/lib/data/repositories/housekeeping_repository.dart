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

import '../../core/business_day.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import '../local/queries/rooms_queries.dart';
import 'outbox.dart';

/// Une chambre a faire, telle que la femme de chambre la voit.
class CleaningJob {
  const CleaningJob({
    required this.roomId,
    this.taskId,
    required this.roomNumber,
    required this.floorLabel,
    required this.roomStatus,
    this.status,
    this.type,
    required this.priority,
    this.startedAt,
    this.durationMinutes,
  });

  /// La tache, si elle existe deja.
  ///
  /// Nulle pour une chambre sale sans tache ouverte -- une chambre salie avant
  /// que ce module n'existe, ou marquee sale a la main. Elle doit quand meme
  /// apparaitre dans la liste : c'est l'etat de la chambre qui dit qu'il y a
  /// du travail, la tache n'en est que la trace.
  final String? taskId;
  final String roomId;
  final String roomNumber;
  final String floorLabel;

  /// L'etat de la chambre : c'est lui qui fait foi pour l'affichage.
  ///
  /// La tache peut manquer ; la chambre, jamais. Lire l'avancement sur elle
  /// evite d'avoir deux verites qui se contredisent a l'ecran.
  final HousekeepingStatus roomStatus;

  /// L'avancement de la tache, ou `null` quand aucune n'a encore ete ouverte.
  final TaskStatus? status;
  final HousekeepingTaskType? type;
  final Priority priority;
  final DateTime? startedAt;
  final int? durationMinutes;

  bool get enCours => roomStatus == HousekeepingStatus.IN_PROGRESS;

  /// La chambre est propre : le travail de la journee est fait.
  bool get faite =>
      roomStatus == HousekeepingStatus.CLEAN ||
      roomStatus == HousekeepingStatus.INSPECTED;

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

  /// Les chambres vacantes qui peuvent demarrer un menage.
  Stream<List<RoomBoardEntry>> watchVacantRooms() => db.watchRoomBoard().map(
    (rooms) => rooms
        .where(
          (room) =>
              room.occupancy == OccupancyStatus.VACANT &&
              !room.isOutOfOrder &&
              room.housekeeping != HousekeepingStatus.IN_PROGRESS,
        )
        .toList(),
  );

  /// Les chambres a faire aujourd'hui, les urgentes d'abord.
  ///
  /// **Pilotee par l'etat des chambres, pas par les taches.** Une chambre
  /// sale sans tache ouverte doit apparaitre : sinon une chambre salie avant
  /// que ce module n'existe, ou marquee sale a la main, reste invisible pour
  /// toujours et personne ne la nettoie. L'etat de la chambre dit qu'il y a du
  /// travail ; la tache n'en est que la trace.
  ///
  /// Les taches terminees restent affichees jusqu'au changement de journee :
  /// une femme de chambre qui vient de finir la 201 doit la voir barree, pas
  /// la voir disparaitre -- sinon elle se demande si son geste a ete pris en
  /// compte.
  /// Un nouveau menage le meme jour remplace la tache terminee a l'affichage
  /// pour conserver une seule carte par chambre et garder son historique.
  Stream<List<CleaningJob>> watchJobs() {
    final jour = businessDateNow();

    return db
        .customSelect(
          """
          SELECT r.id                AS room_id,
                 r.number            AS room_number,
                 r.housekeeping_status AS room_status,
                 COALESCE(f.label, '') AS floor_label,
                 t.id                AS task_id,
                 t.status            AS task_status,
                 t.type              AS type,
                 t.priority          AS priority,
                 t.started_at        AS started_at,
                 t.duration_minutes  AS duration_minutes
            FROM rooms r
       LEFT JOIN floors f ON f.id = r.floor_id
       LEFT JOIN housekeeping_tasks t
                 ON t.room_id = r.id
                AND t.business_date = ?
                AND t.deleted_at IS NULL
                AND t.status <> 'CANCELLED'
                AND t.id = (
                      SELECT latest.id
                        FROM housekeeping_tasks latest
                       WHERE latest.room_id = r.id
                         AND latest.business_date = ?
                         AND latest.deleted_at IS NULL
                         AND latest.status <> 'CANCELLED'
                    ORDER BY CASE WHEN latest.status IN
                             ('PENDING', 'ASSIGNED', 'IN_PROGRESS')
                             THEN 0 ELSE 1 END,
                             latest.created_at DESC, latest.id DESC
                       LIMIT 1
                    )
           WHERE r.deleted_at IS NULL
             AND (r.housekeeping_status IN ('DIRTY', 'IN_PROGRESS')
                  OR t.id IS NOT NULL)
        ORDER BY CASE
                   WHEN r.housekeeping_status = 'IN_PROGRESS' THEN 0
                   WHEN r.housekeeping_status = 'DIRTY'       THEN 1
                   ELSE 2
                 END,
                 CASE COALESCE(t.priority, 'NORMAL')
                   WHEN 'URGENT' THEN 0
                   WHEN 'HIGH'   THEN 1
                   WHEN 'NORMAL' THEN 2
                   ELSE 3
                 END,
                 r.number
          """,
          variables: [Variable.withString(jour), Variable.withString(jour)],
          readsFrom: {db.housekeepingTasks, db.rooms, db.floors},
        )
        .watch()
        .map(
          (lignes) => lignes.map((l) {
            final statut = l.read<String?>('task_status');
            final type = l.read<String?>('type');
            final priorite = l.read<String?>('priority');
            return CleaningJob(
              roomId: l.read<String>('room_id'),
              taskId: l.read<String?>('task_id'),
              roomNumber: l.read<String>('room_number'),
              floorLabel: l.read<String>('floor_label'),
              roomStatus: HousekeepingStatus.values.byName(
                l.read<String>('room_status'),
              ),
              status: statut == null ? null : TaskStatus.values.byName(statut),
              type: type == null
                  ? null
                  : HousekeepingTaskType.values.byName(type),
              priority: priorite == null
                  ? Priority.NORMAL
                  : Priority.values.byName(priorite),
              startedAt: l.read<DateTime?>('started_at'),
              durationMinutes: l.read<int?>('duration_minutes'),
            );
          }).toList(),
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
    final businessDate = businessDateNow();

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

    // CORRIGE (traçabilité, exigence 6.2) : 'created_by' ajoute au payload.
    // La colonne locale createdBy etait deja remplie (dans l'action
    // ci-dessous), mais l'envoi au serveur l'omettait.
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
        'created_by': by,
      },
      action: () async {
        // Ouvrir une tache, c'est declarer qu'il y a du travail : la chambre
        // doit le dire aussi. Sans ca, une tache ouverte sur une chambre
        // marquee propre donnerait deux verites contradictoires a l'ecran,
        // qui lit l'avancement sur la chambre.
        await (db.update(db.rooms)..where(
              (r) =>
                  r.id.equals(roomId) &
                  r.housekeepingStatus.isInValues([
                    HousekeepingStatus.CLEAN,
                    HousekeepingStatus.INSPECTED,
                  ]),
            ))
            .write(
              RoomsCompanion(
                housekeepingStatus: const Value(HousekeepingStatus.DIRTY),
                updatedAt: Value(now),
                syncState: const Value(SyncState.pending),
              ),
            );

        await db
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
            );
      },
    );

    return id;
  }

  /// La femme de chambre commence : la chambre passe en nettoyage.
  ///
  /// La reception le voit aussitot sur son plan -- c'est tout l'interet
  /// d'avoir trois etats plutot que deux. Une chambre en cours de nettoyage
  /// n'est ni sale ni attribuable.
  ///
  /// Prend la **chambre** et non la tache : une chambre sale peut ne pas en
  /// avoir, et refuser de la nettoyer pour cette raison serait absurde. La
  /// tache est ouverte au besoin, puis demarree.
  Future<String> startRoom(String roomId, {String? by}) async {
    final taskId = await openTask(roomId: roomId, by: by);
    await _transition(taskId, TaskStatus.IN_PROGRESS, by: by);
    return taskId;
  }

  /// Lance ensemble le menage des chambres vacantes selectionnees.
  ///
  /// Revérifie toutes les chambres avant d'ecrire. Si une chambre n'est plus
  /// libre, aucune chambre du groupe ne change et aucune action n'est enfilee.
  Future<int> startVacantRooms(
    Iterable<String> roomIds, {
    required String by,
  }) async {
    final ids = roomIds.toSet();
    if (ids.isEmpty) throw StateError('Sélectionnez au moins une chambre.');
    return db.transaction(() async {
      final rooms = await (db.select(
        db.rooms,
      )..where((r) => r.id.isIn(ids))).get();
      if (rooms.length != ids.length) {
        throw StateError('Une chambre sélectionnée est introuvable.');
      }
      for (final room in rooms) {
        if (room.deletedAt != null ||
            !room.isActive ||
            room.occupancyStatus != OccupancyStatus.VACANT ||
            room.isOutOfOrder ||
            room.housekeepingStatus == HousekeepingStatus.IN_PROGRESS) {
          throw StateError(
            'La chambre ${room.number} ne peut plus démarrer un ménage. Actualisez votre sélection.',
          );
        }
      }
      for (final room in rooms) {
        final taskId = await openTask(
          roomId: room.id,
          type: HousekeepingTaskType.REFRESH,
          by: by,
        );
        await _transition(taskId, TaskStatus.IN_PROGRESS, by: by);
      }
      return rooms.length;
    });
  }

  /// La femme de chambre a fini : la chambre redevient disponible.
  Future<void> finish(String taskId, {String? by}) =>
      _transition(taskId, TaskStatus.DONE, by: by);

  /// Demarre une tache deja ouverte. Utilise par les tests et le rejeu.
  Future<void> start(String taskId, {String? by}) =>
      _transition(taskId, TaskStatus.IN_PROGRESS, by: by);

  /// Corrige un avancement saisi par erreur, sans supprimer la tache.
  Future<void> revertRoom(
    String roomId, {
    required HousekeepingStatus to,
    required String by,
  }) => db.transaction(() async {
    final room = await (db.select(
      db.rooms,
    )..where((r) => r.id.equals(roomId))).getSingleOrNull();
    if (room == null || room.deletedAt != null) {
      throw StateError('Chambre introuvable.');
    }
    final autorise = switch ((room.housekeepingStatus, to)) {
      (HousekeepingStatus.IN_PROGRESS, HousekeepingStatus.DIRTY) => true,
      (
        HousekeepingStatus.CLEAN || HousekeepingStatus.INSPECTED,
        HousekeepingStatus.DIRTY || HousekeepingStatus.IN_PROGRESS,
      ) =>
        true,
      _ => false,
    };
    if (!autorise) {
      throw StateError('Ce retour n’est plus possible. Actualisez le tableau.');
    }
    final tasks =
        await (db.select(db.housekeepingTasks)
              ..where(
                (t) =>
                    t.roomId.equals(roomId) &
                    t.deletedAt.isNull() &
                    t.businessDate.equals(businessDateNow()) &
                    t.status.isNotInValues([TaskStatus.CANCELLED]),
              )
              ..orderBy([
                (t) => OrderingTerm.desc(t.createdAt),
                (t) => OrderingTerm.desc(t.id),
              ])
              ..limit(1))
            .get();
    if (tasks.isEmpty) {
      throw StateError('Aucune tâche à corriger pour cette chambre.');
    }
    final task = tasks.single;
    final status = to == HousekeepingStatus.DIRTY
        ? TaskStatus.PENDING
        : TaskStatus.IN_PROGRESS;
    final now = DateTime.now().toUtc();
    await writeAndEnqueue(
      table: 'housekeeping_tasks',
      id: task.id,
      operation: SyncOp.UPDATE,
      payload: {
        'id': task.id,
        'action': 'REVERT',
        'from_status': task.status.name,
        'status': status.name,
        'assigned_to': by,
      },
      action: () async {
        await (db.update(
          db.housekeepingTasks,
        )..where((t) => t.id.equals(task.id))).write(
          HousekeepingTasksCompanion(
            status: Value(status),
            assignedTo: Value(to == HousekeepingStatus.DIRTY ? null : by),
            assignedAt: to == HousekeepingStatus.DIRTY
                ? const Value(null)
                : const Value.absent(),
            startedAt: Value(
              to == HousekeepingStatus.DIRTY ? null : task.startedAt ?? now,
            ),
            finishedAt: const Value(null),
            durationMinutes: const Value(null),
            inspectedBy: const Value(null),
            inspectedAt: const Value(null),
            updatedBy: Value(by),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
        await (db.update(db.rooms)..where((r) => r.id.equals(roomId))).write(
          RoomsCompanion(
            housekeepingStatus: Value(to),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
      },
    );
  });

  Future<void> _transition(String taskId, TaskStatus vers, {String? by}) async {
    final tache = await (db.select(
      db.housekeepingTasks,
    )..where((t) => t.id.equals(taskId))).getSingleOrNull();

    if (tache == null) throw StateError('Tache introuvable.');
    if (tache.status == vers) return; // deja fait, rien a refaire

    final now = DateTime.now().toUtc();
    final demarre = vers == TaskStatus.IN_PROGRESS;

    if (!demarre && tache.status != TaskStatus.IN_PROGRESS) {
      throw StateError('Il faut commencer le menage avant de le terminer.');
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
      //
      // CORRIGE (traçabilité, exigence 6.2) : 'assigned_to' ajoute au
      // payload, par symetrie avec la colonne locale `assignedTo`.
      // HYPOTHESE A CONFIRMER : ce nom suppose que le serveur attend bien
      // 'assigned_to' et non un autre champ (started_by / finished_by...) —
      // a verifier avec l'equipe backend avant le merge (voir tableau
      // d'inventaire de l'etape 2).
      await enqueue(
        table: 'housekeeping_tasks',
        id: taskId,
        operation: SyncOp.UPDATE,
        payload: {'id': taskId, 'status': vers.name, 'assigned_to': by},
      );
    });
  }
}
