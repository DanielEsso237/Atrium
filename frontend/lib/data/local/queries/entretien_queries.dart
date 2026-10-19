/// Le tableau de bord et l'historique de l'entretien (demande du 18
/// octobre) : les taches de menage et les pannes, chacune avec tous ses
/// temps -- creee, commencee, finie, controlee ; signalee, prise en main,
/// reglee, close.
///
/// Deux lectures seulement, que le tableau de bord et l'historique
/// decoupent chacun a leur facon : ce qui reste a faire, ce qui a ete fait
/// jour par jour, par qui et en combien de temps.
///
/// Les taches et les pannes ne descendent pas du serveur : l'historique
/// montre ce que cette tablette a enregistre.
library;

import 'package:drift/drift.dart';

import '../database.dart';
import '../enums.dart';

/// Une tache de menage.
class TacheMenage {
  const TacheMenage({
    required this.id,
    required this.chambre,
    required this.type,
    required this.statut,
    required this.priorite,
    required this.jour,
    this.agent,
    this.creeLe,
    this.commenceLe,
    this.termineLe,
    this.duree,
    this.inspectePar,
    this.inspecteLe,
  });

  final String id;
  final String chambre;
  final HousekeepingTaskType type;
  final TaskStatus statut;
  final Priority priorite;

  /// La journee hoteliere de la tache.
  final DateTime jour;

  /// La femme de chambre a qui elle est confiee.
  final String? agent;
  final DateTime? creeLe;
  final DateTime? commenceLe;
  final DateTime? termineLe;

  /// En minutes, quand elle est finie.
  final int? duree;
  final String? inspectePar;
  final DateTime? inspecteLe;

  bool get faite =>
      statut == TaskStatus.DONE || statut == TaskStatus.INSPECTED;
  bool get aFaire =>
      statut == TaskStatus.PENDING ||
      statut == TaskStatus.ASSIGNED ||
      statut == TaskStatus.IN_PROGRESS;
}

/// Une panne, de son signalement a sa cloture.
class PanneEntretien {
  const PanneEntretien({
    required this.id,
    required this.numero,
    required this.titre,
    required this.priorite,
    required this.statut,
    required this.cout,
    required this.bloqueChambre,
    this.chambre,
    this.lieu,
    this.signalePar,
    this.signaleLe,
    this.assigneA,
    this.assigneLe,
    this.regleeLe,
    this.closeLe,
    this.resolution,
  });

  final String id;
  final String numero;
  final String titre;
  final Priority priorite;
  final TicketStatus statut;

  /// Ce que la reparation a coute, en francs CFA.
  final int cout;

  /// La chambre ne se loue pas tant que la panne n'est pas reglee.
  final bool bloqueChambre;
  final String? chambre;
  final String? lieu;
  final String? signalePar;
  final DateTime? signaleLe;
  final String? assigneA;
  final DateTime? assigneLe;
  final DateTime? regleeLe;
  final DateTime? closeLe;
  final String? resolution;

  bool get ouverte =>
      statut == TicketStatus.OPEN ||
      statut == TicketStatus.ASSIGNED ||
      statut == TicketStatus.IN_PROGRESS;
  bool get urgente =>
      priorite == Priority.URGENT || priorite == Priority.HIGH;

  /// Ou elle est : la chambre, sinon le lieu.
  String get ou =>
      chambre != null ? 'Chambre $chambre' : (lieu ?? 'Sans lieu précis');
}

extension EntretienQueries on AtriumDatabase {
  /// Les taches de menage depuis la journee [depuis] (toutes sans elle), et
  /// toutes celles qui restent a faire, les plus recentes d'abord.
  Stream<List<TacheMenage>> watchTachesMenage({String? depuis}) {
    return customSelect(
      '''
      SELECT t.id, t.type, t.status, t.priority, t.business_date,
             t.created_at, t.started_at, t.finished_at, t.duration_minutes,
             t.inspected_at,
             r.number AS chambre,
             a.first_name AS agent_prenom, a.last_name AS agent_nom,
             i.first_name AS inspecte_prenom, i.last_name AS inspecte_nom
        FROM housekeeping_tasks t
        JOIN rooms r ON r.id = t.room_id
        LEFT JOIN users a ON a.id = t.assigned_to
        LEFT JOIN users i ON i.id = t.inspected_by
       WHERE t.deleted_at IS NULL
         AND (?1 IS NULL OR t.business_date >= ?1
              OR t.status IN ('PENDING', 'ASSIGNED', 'IN_PROGRESS'))
       ORDER BY COALESCE(t.finished_at, t.started_at, t.created_at) DESC
      ''',
      variables: [Variable<String>(depuis)],
      readsFrom: {housekeepingTasks, rooms, users},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          TacheMenage(
            id: r.read<String>('id'),
            chambre: r.read<String>('chambre'),
            type: HousekeepingTaskType.values.byName(r.read<String>('type')),
            statut: TaskStatus.values.byName(r.read<String>('status')),
            priorite: Priority.values.byName(r.read<String>('priority')),
            jour: DateTime.parse(r.read<String>('business_date')),
            agent: _nom(r, 'agent_prenom', 'agent_nom'),
            creeLe: r.readNullable<DateTime>('created_at'),
            commenceLe: r.readNullable<DateTime>('started_at'),
            termineLe: r.readNullable<DateTime>('finished_at'),
            duree: r.readNullable<int>('duration_minutes'),
            inspectePar: _nom(r, 'inspecte_prenom', 'inspecte_nom'),
            inspecteLe: r.readNullable<DateTime>('inspected_at'),
          ),
      ],
    );
  }

  /// Les pannes signalees ou reglees depuis [depuis] (toutes sans lui), et
  /// toutes celles qui restent ouvertes, les plus recentes d'abord.
  Stream<List<PanneEntretien>> watchPannes({DateTime? depuis}) {
    return customSelect(
      '''
      SELECT m.id, m.number, m.title, m.location, m.priority, m.status,
             m.reported_at, m.assigned_at, m.resolved_at, m.closed_at,
             m.resolution, m.cost, m.blocks_room,
             r.number AS chambre,
             s.first_name AS signale_prenom, s.last_name AS signale_nom,
             a.first_name AS assigne_prenom, a.last_name AS assigne_nom
        FROM maintenance_tickets m
        LEFT JOIN rooms r ON r.id = m.room_id
        LEFT JOIN users s ON s.id = m.reported_by
        LEFT JOIN users a ON a.id = m.assigned_to
       WHERE m.deleted_at IS NULL
         AND (?1 IS NULL
              OR COALESCE(m.closed_at, m.resolved_at, m.reported_at,
                          m.created_at) >= ?1
              OR m.status IN ('OPEN', 'ASSIGNED', 'IN_PROGRESS'))
       ORDER BY COALESCE(m.reported_at, m.created_at) DESC
      ''',
      variables: [Variable<DateTime>(depuis?.toUtc())],
      readsFrom: {maintenanceTickets, rooms, users},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          PanneEntretien(
            id: r.read<String>('id'),
            numero: r.read<String>('number'),
            titre: r.read<String>('title'),
            lieu: r.readNullable<String>('location'),
            chambre: r.readNullable<String>('chambre'),
            priorite: Priority.values.byName(r.read<String>('priority')),
            statut: TicketStatus.values.byName(r.read<String>('status')),
            signalePar: _nom(r, 'signale_prenom', 'signale_nom'),
            signaleLe: r.readNullable<DateTime>('reported_at'),
            assigneA: _nom(r, 'assigne_prenom', 'assigne_nom'),
            assigneLe: r.readNullable<DateTime>('assigned_at'),
            regleeLe: r.readNullable<DateTime>('resolved_at'),
            closeLe: r.readNullable<DateTime>('closed_at'),
            resolution: r.readNullable<String>('resolution'),
            cout: r.read<int>('cost'),
            bloqueChambre: r.read<bool>('blocks_room'),
          ),
      ],
    );
  }

  static String? _nom(QueryRow r, String prenom, String nom) {
    final n =
        '${r.readNullable<String>(prenom) ?? ''} '
                '${r.readNullable<String>(nom) ?? ''}'
            .trim();
    return n.isEmpty ? null : n;
  }
}
