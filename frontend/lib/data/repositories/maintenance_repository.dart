/// Les tickets de maintenance (cahier des charges, F2.3, F4.1-F4.4).
///
/// Un probleme se signale la ou il est vu -- dans la chambre, dans la
/// chaufferie -- c'est-a-dire souvent la ou le wifi ne passe pas. Comme tout
/// le reste, le ticket s'ecrit donc d'abord dans la base locale et part par la
/// file d'envoi.
///
/// Le cycle tient en quatre etats, un geste chacun :
///
/// - **ouvert** : signale, personne ne s'en occupe encore ;
/// - **pris en charge** : un agent l'a pris (`/assign`) ;
/// - **resolu** : la reparation est faite, avec un mot sur ce qui a ete fait
///   (`/resolve`) ;
/// - **clos** : verifie et range (`/close`). C'est la cloture qui rend la
///   chambre a la vente si le ticket l'avait bloquee -- le serveur fait de
///   meme, la tablette l'applique tout de suite pour que le plan le montre.
///
/// Les passages de technicien (`/interventions`) ne sont pas encore exposes :
/// leur envoi n'est pas rejouable cote serveur (pas d'id fourni par la
/// tablette), et un renvoi creerait un second passage.
library;

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// Un ticket, tel que l'ecran l'affiche.
class TicketSummary {
  const TicketSummary({
    required this.id,
    required this.number,
    required this.title,
    required this.description,
    required this.priority,
    required this.status,
    required this.blocksRoom,
    required this.roomNumber,
    required this.location,
    required this.reportedAt,
    required this.reporterName,
    required this.assigneeName,
    required this.resolution,
  });

  final String id;
  final String number;
  final String title;
  final String? description;
  final Priority priority;
  final TicketStatus status;
  final bool blocksRoom;
  final String? roomNumber;
  final String? location;
  final DateTime? reportedAt;
  final String? reporterName;
  final String? assigneeName;
  final String? resolution;

  bool get urgent => priority == Priority.URGENT || priority == Priority.HIGH;
}

/// Une chambre a laquelle rattacher un ticket.
class TicketRoomOption {
  const TicketRoomOption({required this.id, required this.number});

  final String id;
  final String number;
}

class MaintenanceRepository with OutboxWriter {
  MaintenanceRepository(this.db);

  @override
  final AtriumDatabase db;

  static const hotelId = '01920000-0000-7000-8000-000000000001';

  /// Tous les tickets, les ouverts d'abord, les urgents en tete.
  Stream<List<TicketSummary>> watchTickets() {
    return db
        .customSelect(
          '''
          SELECT t.id, t.number, t.title, t.description, t.priority, t.status,
                 t.blocks_room, t.location, t.reported_at, t.resolution,
                 r.number AS room_number,
                 rep.first_name AS rep_first, rep.last_name AS rep_last,
                 ass.first_name AS ass_first, ass.last_name AS ass_last
            FROM maintenance_tickets t
            LEFT JOIN rooms r   ON r.id = t.room_id
            LEFT JOIN users rep ON rep.id = t.reported_by
            LEFT JOIN users ass ON ass.id = t.assigned_to
           WHERE t.deleted_at IS NULL
           ORDER BY CASE t.priority
                      WHEN 'URGENT' THEN 0 WHEN 'HIGH' THEN 1
                      WHEN 'NORMAL' THEN 2 ELSE 3 END,
                    t.reported_at DESC
          ''',
          readsFrom: {db.maintenanceTickets, db.rooms, db.users},
        )
        .watch()
        .map(
          (rows) => [
            for (final r in rows)
              TicketSummary(
                id: r.read<String>('id'),
                number: r.read<String>('number'),
                title: r.read<String>('title'),
                description: r.readNullable<String>('description'),
                priority: Priority.values.byName(r.read<String>('priority')),
                status: TicketStatus.values.byName(r.read<String>('status')),
                blocksRoom: r.read<bool>('blocks_room'),
                location: r.readNullable<String>('location'),
                reportedAt: r.readNullable<DateTime>('reported_at'),
                resolution: r.readNullable<String>('resolution'),
                roomNumber: r.readNullable<String>('room_number'),
                reporterName: _nom(
                  r.readNullable<String>('rep_first'),
                  r.readNullable<String>('rep_last'),
                ),
                assigneeName: _nom(
                  r.readNullable<String>('ass_first'),
                  r.readNullable<String>('ass_last'),
                ),
              ),
          ],
        );
  }

  /// Les chambres, par numero, pour rattacher un ticket.
  Future<List<TicketRoomOption>> rooms() async {
    final rows =
        await (db.select(db.rooms)
              ..where((r) => r.deletedAt.isNull())
              ..orderBy([(r) => OrderingTerm(expression: r.number)]))
            .get();
    return [for (final r in rows) TicketRoomOption(id: r.id, number: r.number)];
  }

  static String? _nom(String? prenom, String? nom) {
    final t = [prenom, nom].whereType<String>().join(' ').trim();
    return t.isEmpty ? null : t;
  }

  /// Signale un probleme.
  ///
  /// Un ticket qui **bloque la chambre** la sort de la vente tout de suite,
  /// comme le fait le serveur : une fuite d'eau ne doit pas attendre la
  /// prochaine synchronisation pour disparaitre du plan.
  Future<String> create({
    required String title,
    String? description,
    String? roomId,
    String? location,
    Priority priority = Priority.NORMAL,
    bool blocksRoom = false,
    String? by,
  }) async {
    final id = newId();
    final now = DateTime.now().toUtc();
    // Numero provisoire : le numero legal est attribue par le serveur, comme
    // pour les factures. Il sert a retrouver le ticket d'ici la.
    final numero = 'MT-${id.substring(id.length - 6).toUpperCase()}';
    final bloque = blocksRoom && roomId != null;

    await writeAndEnqueue(
      table: 'maintenance_tickets',
      id: id,
      operation: SyncOp.INSERT,
      payload: {
        'id': id,
        'room_id': roomId,
        'location': location,
        'title': title.trim(),
        'description': description,
        'priority': priority.name,
        'blocks_room': bloque,
      },
      action: () async {
        await db
            .into(db.maintenanceTickets)
            .insert(
              MaintenanceTicketsCompanion.insert(
                id: id,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                number: numero,
                roomId: Value(roomId),
                location: Value(location),
                title: title.trim(),
                description: Value(description),
                priority: Value(priority),
                status: const Value(TicketStatus.OPEN),
                reportedBy: Value(by),
                reportedAt: Value(now),
                blocksRoom: Value(bloque),
                createdBy: Value(by),
                syncState: const Value(SyncState.pending),
              ),
            );
        if (bloque) {
          await (db.update(db.rooms)..where((r) => r.id.equals(roomId))).write(
            RoomsCompanion(
              isOutOfOrder: const Value(true),
              updatedAt: Value(now),
              syncState: const Value(SyncState.pending),
            ),
          );
        }
      },
    );
    return id;
  }

  /// « Je m'en occupe » : l'agent connecte prend le ticket.
  Future<void> take(String ticketId, {required String by}) => _transition(
    ticketId,
    TicketStatus.ASSIGNED,
    depuis: {TicketStatus.OPEN},
    by: by,
  );

  /// La reparation est faite.
  Future<void> resolve(
    String ticketId, {
    required String resolution,
    String? by,
  }) => _transition(
    ticketId,
    TicketStatus.RESOLVED,
    depuis: {TicketStatus.ASSIGNED, TicketStatus.IN_PROGRESS},
    resolution: resolution.trim(),
    by: by,
  );

  /// Verifie et range : la chambre revient a la vente si le ticket l'avait
  /// bloquee.
  Future<void> close(String ticketId, {String? by}) => _transition(
    ticketId,
    TicketStatus.CLOSED,
    depuis: {TicketStatus.RESOLVED},
    by: by,
  );

  /// Ramene un ticket a une etape precedente apres une erreur de saisie.
  Future<void> revert(
    String ticketId, {
    required TicketStatus to,
    required String by,
  }) => db.transaction(() async {
    final t = await (db.select(
      db.maintenanceTickets,
    )..where((t) => t.id.equals(ticketId))).getSingleOrNull();
    if (t == null || t.deletedAt != null) {
      throw StateError('Ticket introuvable.');
    }
    final autorise = switch ((t.status, to)) {
      (TicketStatus.ASSIGNED || TicketStatus.IN_PROGRESS, TicketStatus.OPEN) =>
        true,
      (TicketStatus.RESOLVED, TicketStatus.OPEN || TicketStatus.ASSIGNED) =>
        true,
      (TicketStatus.CLOSED, TicketStatus.RESOLVED) => true,
      _ => false,
    };
    if (!autorise) {
      throw StateError('Ce retour n’est plus possible. Actualisez le tableau.');
    }
    final now = DateTime.now().toUtc();
    await writeAndEnqueue(
      table: 'maintenance_tickets',
      id: ticketId,
      operation: SyncOp.UPDATE,
      payload: {
        'id': ticketId,
        'action': 'REVERT',
        'from_status': t.status.name,
        'status': to.name,
      },
      action: () async {
        await (db.update(
          db.maintenanceTickets,
        )..where((t) => t.id.equals(ticketId))).write(
          MaintenanceTicketsCompanion(
            status: Value(to),
            assignedTo: to == TicketStatus.OPEN
                ? const Value(null)
                : const Value.absent(),
            assignedAt: to == TicketStatus.OPEN
                ? const Value(null)
                : const Value.absent(),
            resolvedAt: to == TicketStatus.RESOLVED
                ? const Value.absent()
                : const Value(null),
            resolution: to == TicketStatus.RESOLVED
                ? const Value.absent()
                : const Value(null),
            closedAt: const Value(null),
            updatedBy: Value(by),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
        if (t.status == TicketStatus.CLOSED &&
            t.blocksRoom &&
            t.roomId != null) {
          await (db.update(
            db.rooms,
          )..where((r) => r.id.equals(t.roomId!))).write(
            RoomsCompanion(
              isOutOfOrder: const Value(true),
              updatedAt: Value(now),
              syncState: const Value(SyncState.pending),
            ),
          );
        }
      },
    );
  });

  Future<void> _transition(
    String ticketId,
    TicketStatus vers, {
    required Set<TicketStatus> depuis,
    String? resolution,
    String? by,
  }) async {
    final t = await (db.select(
      db.maintenanceTickets,
    )..where((x) => x.id.equals(ticketId))).getSingleOrNull();
    if (t == null) throw StateError('Ticket introuvable.');
    if (t.status == vers) return; // deja fait
    if (!depuis.contains(t.status)) {
      throw StateError(switch (vers) {
        TicketStatus.RESOLVED =>
          "Il faut prendre le ticket avant de le résoudre.",
        TicketStatus.CLOSED => 'Il faut résoudre le ticket avant de le clore.',
        _ => 'Ce ticket a déjà été pris.',
      });
    }

    final now = DateTime.now().toUtc();
    final assigne = vers == TicketStatus.ASSIGNED ? by : t.assignedTo;

    await writeAndEnqueue(
      table: 'maintenance_tickets',
      id: ticketId,
      operation: SyncOp.UPDATE,
      // L'etat vise et ce dont son endpoint a besoin : le serveur a une route
      // par transition, qui pose elle-meme les horodatages.
      payload: {
        'id': ticketId,
        'status': vers.name,
        'assigned_to': assigne,
        'resolution': resolution,
      },
      action: () async {
        await (db.update(
          db.maintenanceTickets,
        )..where((x) => x.id.equals(ticketId))).write(
          MaintenanceTicketsCompanion(
            status: Value(vers),
            assignedTo: vers == TicketStatus.ASSIGNED
                ? Value(by)
                : const Value.absent(),
            assignedAt: vers == TicketStatus.ASSIGNED
                ? Value(now)
                : const Value.absent(),
            resolvedAt: vers == TicketStatus.RESOLVED
                ? Value(now)
                : const Value.absent(),
            resolution: resolution == null
                ? const Value.absent()
                : Value(resolution),
            closedAt: vers == TicketStatus.CLOSED
                ? Value(now)
                : const Value.absent(),
            updatedBy: Value(by),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
        if (vers == TicketStatus.CLOSED && t.blocksRoom && t.roomId != null) {
          await (db.update(
            db.rooms,
          )..where((r) => r.id.equals(t.roomId!))).write(
            RoomsCompanion(
              isOutOfOrder: const Value(false),
              updatedAt: Value(now),
              syncState: const Value(SyncState.pending),
            ),
          );
        }
      },
    );
  }
}
