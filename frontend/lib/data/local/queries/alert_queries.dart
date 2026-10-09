/// Les alertes : ce qu'un agent ne doit pas manquer, calcule a partir de la
/// base locale.
///
/// Une alerte n'est pas stockee : elle se deduit de l'etat, comme la
/// pastille d'une chambre. Une saisie refusee, une chambre a faire, une panne
/// urgente, un client qui aurait du partir -- tant que la situation dure,
/// l'alerte existe ; quand elle est reglee, l'alerte disparait d'elle-meme.
/// Ecrire des alertes dans une table synchronisee aurait demande de les
/// faire remonter, pour un serveur qui n'en a que faire.
///
/// Chaque alerte porte une cle stable : c'est elle que l'agent acquitte, et
/// une nouvelle situation (une autre panne, un autre refus) fait une nouvelle
/// cle, donc une nouvelle sonnerie.
library;

import 'package:drift/drift.dart';

import '../../../core/business_day.dart';
import '../../../core/formats.dart';
import '../../../core/prolongation.dart';
import '../database.dart';
import '../enums.dart';

/// De la plus discrete a la plus forte.
enum NiveauAlerte {
  /// Dans la cloche, une vibration breve.
  info,

  /// Bandeau, carillon et vibration : quelqu'un attend une action.
  urgente,

  /// Bandeau rouge, alarme repetee jusqu'a l'acquittement : le travail de
  /// la tablette ou d'un client est bloque.
  critique,
}

class Alerte {
  const Alerte({
    required this.cle,
    required this.niveau,
    required this.titre,
    required this.corps,
    this.route,
    this.depuis,
  });

  final String cle;
  final NiveauAlerte niveau;
  final String titre;
  final String corps;

  /// L'ecran ou la regler ; `null` quand il n'y en a pas.
  final String? route;
  final DateTime? depuis;

  @override
  bool operator ==(Object other) =>
      other is Alerte &&
      other.cle == cle &&
      other.niveau == niveau &&
      other.titre == titre &&
      other.corps == corps;

  @override
  int get hashCode => Object.hash(cle, niveau, titre, corps);
}

/// Pour qui on calcule : les alertes suivent les droits de l'agent.
class ContexteAlertes {
  const ContexteAlertes({
    required this.agentId,
    required this.peut,
    required this.maintenant,
    this.accueil,
  });

  final String? agentId;
  final bool Function(String permission) peut;
  final DateTime maintenant;

  /// L'ecran d'accueil du metier : `/menage` pour une femme de chambre.
  final String? accueil;

  /// La reception et la direction : celles qui ouvrent sur le tableau de
  /// bord, pas sur un ecran unique.
  bool get poste => accueil == null || accueil == '/';
}

String libelleTypeMenage(HousekeepingTaskType t) => switch (t) {
  HousekeepingTaskType.DEPARTURE => 'Départ',
  HousekeepingTaskType.STAYOVER => 'Recouche',
  HousekeepingTaskType.REFRESH => 'Rafraîchissement',
  HousekeepingTaskType.DEEP_CLEAN => 'Grand ménage',
  HousekeepingTaskType.INSPECTION => 'Contrôle',
};

extension AlertQueries on AtriumDatabase {
  /// Les tables dont un changement peut faire naitre ou disparaitre une
  /// alerte.
  Stream<Set<TableUpdate>> changementsAlertes() => tableUpdates(
    TableUpdateQuery.onAllTables([
      outboxEntries,
      housekeepingTasks,
      maintenanceTickets,
      reservationRooms,
      folioItems,
      stockLevels,
      products,
    ]),
  );

  /// Les alertes en cours, de la plus forte a la plus discrete.
  Future<List<Alerte>> chargerAlertes(ContexteAlertes c) async {
    final alertes = [
      ...await _envoiBloque(),
      if (c.peut('housekeeping.read')) ...await _menage(c),
      if (c.peut('maintenance.read')) ...await _pannes(),
      if (c.peut('reservation.read') && c.poste) ...await _departs(c),
      if (c.peut('stock.read')) ...await _ruptures(),
    ];
    alertes.sort((a, b) {
      final n = b.niveau.index.compareTo(a.niveau.index);
      if (n != 0) return n;
      return (a.depuis ?? c.maintenant).compareTo(b.depuis ?? c.maintenant);
    });
    return alertes;
  }

  /// Une saisie refusee par le serveur bloque toute la file derriere elle :
  /// plus rien ne remonte, et personne ne le voit sur un autre poste.
  Future<List<Alerte>> _envoiBloque() async {
    final l = await customSelect(
      '''
      SELECT e.id AS id, e.last_error AS erreur, e.last_attempt_at AS moment,
             (SELECT COUNT(*) FROM outbox_entries
               WHERE status IN ('PENDING','SENDING','FAILED')) AS attente
        FROM outbox_entries e
       WHERE e.status = 'FAILED'
       ORDER BY e.id
       LIMIT 1
      ''',
      readsFrom: {outboxEntries},
    ).getSingleOrNull();
    if (l == null) return const [];
    final attente = l.read<int>('attente');
    final erreur = l.readNullable<String>('erreur')?.trim();
    return [
      Alerte(
        cle: 'envoi-${l.read<int>('id')}',
        niveau: NiveauAlerte.critique,
        titre: 'Envoi bloqué : le serveur refuse une saisie',
        corps:
            '${erreur == null || erreur.isEmpty ? 'Refus sans motif' : erreur}. '
            '$attente saisie${attente > 1 ? 's attendent' : ' attend'} : rien '
            'ne remonte tant que ce refus n’est pas réglé.',
        depuis: l.readNullable<DateTime>('moment'),
      ),
    ];
  }

  /// Les chambres a faire de l'agent, ou de toute l'equipe pour une femme
  /// de chambre quand personne n'est encore designe.
  Future<List<Alerte>> _menage(ContexteAlertes c) async {
    final menage = c.accueil == '/menage';
    if (c.agentId == null && !menage) return const [];
    final lignes = await customSelect(
      '''
      SELECT t.id AS id, t.type AS type, t.priority AS priorite,
             t.created_at AS moment, r.number AS chambre
        FROM housekeeping_tasks t
        LEFT JOIN rooms r ON r.id = t.room_id
       WHERE t.deleted_at IS NULL
         AND t.status IN ('PENDING','ASSIGNED')
         AND t.business_date <= ?1
         AND (t.assigned_to = ?2 OR (t.assigned_to IS NULL AND ?3 = 1))
      ''',
      variables: [
        Variable.withString(businessDateNow(at: c.maintenant)),
        Variable<String>(c.agentId),
        Variable.withBool(menage),
      ],
      readsFrom: {housekeepingTasks, rooms},
    ).get();
    return [
      for (final l in lignes)
        Alerte(
          cle: 'menage-${l.read<String>('id')}',
          niveau: l.read<String>('priorite') == Priority.URGENT.name
              ? NiveauAlerte.critique
              : NiveauAlerte.urgente,
          titre: 'Chambre ${l.readNullable<String>('chambre') ?? '?'} à faire',
          corps: [
            _typeMenage(l.read<String>('type')),
            if (l.read<String>('priorite') == Priority.URGENT.name)
              'client en attente'
            else if (l.read<String>('priorite') == Priority.HIGH.name)
              'priorité haute',
          ].join(', '),
          route: '/menage',
          depuis: l.readNullable<DateTime>('moment'),
        ),
    ];
  }

  /// Les pannes urgentes ou prioritaires encore ouvertes.
  Future<List<Alerte>> _pannes() async {
    final lignes = await customSelect(
      '''
      SELECT t.id AS id, t.title AS titre, t.priority AS priorite,
             t.location AS lieu, t.blocks_room AS bloque,
             COALESCE(t.reported_at, t.created_at) AS moment,
             r.number AS chambre
        FROM maintenance_tickets t
        LEFT JOIN rooms r ON r.id = t.room_id
       WHERE t.deleted_at IS NULL
         AND t.status IN ('OPEN','ASSIGNED','IN_PROGRESS')
         AND t.priority IN ('HIGH','URGENT')
      ''',
      readsFrom: {maintenanceTickets, rooms},
    ).get();
    return [
      for (final l in lignes)
        Alerte(
          cle: 'panne-${l.read<String>('id')}',
          niveau: l.read<String>('priorite') == Priority.URGENT.name
              ? NiveauAlerte.critique
              : NiveauAlerte.urgente,
          titre: l.read<String>('priorite') == Priority.URGENT.name
              ? 'Panne urgente : ${l.read<String>('titre')}'
              : 'Panne prioritaire : ${l.read<String>('titre')}',
          corps: [
            if (l.readNullable<String>('chambre') case final ch?)
              'Chambre $ch'
            else
              ?l.readNullable<String>('lieu'),
            if (l.read<bool>('bloque')) 'la chambre ne peut pas être louée',
          ].join(', ').ifEmpty('Lieu non précisé'),
          route: '/maintenance',
          depuis: l.readNullable<DateTime>('moment'),
        ),
    ];
  }

  /// Les clients encore dans leur chambre apres l'heure de depart,
  /// prolongations comprises.
  Future<List<Alerte>> _departs(ContexteAlertes c) async {
    final lignes = await customSelect(
      '''
      SELECT rr.id AS id, rr.departure_date AS depart, r.number AS chambre,
             g.first_name AS prenom, g.last_name AS nom,
             (SELECT COALESCE(SUM(fi.quantity), 0)
                FROM folios f
                JOIN folio_items fi ON fi.folio_id = f.id
               WHERE f.reservation_room_id = rr.id
                 AND fi.deleted_at IS NULL
                 AND fi.is_void = 0
                 AND fi.label LIKE ?2) AS heures
        FROM reservation_rooms rr
        LEFT JOIN rooms r        ON r.id = rr.room_id
        LEFT JOIN reservations d ON d.id = rr.reservation_id
        LEFT JOIN guests g       ON g.id = d.guest_id
       WHERE rr.deleted_at IS NULL
         AND rr.status = 'CHECKED_IN'
         AND rr.departure_date <= ?1
      ''',
      variables: [
        Variable.withString(formatIsoDate(c.maintenant)),
        Variable.withString('$libelleProlongation%'),
      ],
      readsFrom: {reservationRooms, rooms, reservations, guests, folios,
        folioItems},
    ).get();
    final alertes = <Alerte>[];
    for (final l in lignes) {
      final limite = limiteDeDepart(
        parseIsoDate(l.read<String>('depart'))!,
        heuresProlongees: l.read<int>('heures'),
      );
      if (!c.maintenant.isAfter(limite)) continue;
      final client = [
        l.readNullable<String>('prenom'),
        l.readNullable<String>('nom'),
      ].whereType<String>().join(' ').trim();
      alertes.add(
        Alerte(
          // La limite dans la cle : une prolongation la repousse, et son
          // depassement sonne de nouveau.
          cle: 'depart-${l.read<String>('id')}-${limite.toIso8601String()}',
          niveau: NiveauAlerte.urgente,
          titre: 'Départ dépassé : chambre '
              '${l.readNullable<String>('chambre') ?? '?'}',
          corps:
              '${client.isEmpty ? 'Le client' : client} devait partir à '
              '${formatHeure(limite)}${limite.day != c.maintenant.day ? ' le ${formatDayMonth(limite)}' : ''}. '
              'Faites le départ ou prolongez le séjour.',
          route: '/reservations',
          depuis: limite,
        ),
      );
    }
    return alertes;
  }

  /// Les produits suivis qui n'ont plus rien en stock.
  Future<List<Alerte>> _ruptures() async {
    final lignes = await customSelect(
      '''
      SELECT p.id AS id, p.label AS libelle
        FROM products p
       WHERE p.deleted_at IS NULL
         AND p.is_active = 1
         AND p.min_stock > 0
         AND COALESCE((SELECT SUM(l.quantity) FROM stock_levels l
                        WHERE l.product_id = p.id
                          AND l.deleted_at IS NULL), 0) <= 0
       ORDER BY p.label
      ''',
      readsFrom: {products, stockLevels},
    ).get();
    return [
      for (final l in lignes)
        Alerte(
          cle: 'rupture-${l.read<String>('id')}',
          niveau: NiveauAlerte.info,
          titre: 'Rupture : ${l.read<String>('libelle')}',
          corps: 'Plus aucune unité en stock. Pensez à réapprovisionner.',
          route: '/stocks',
        ),
    ];
  }

  static String _typeMenage(String v) {
    for (final t in HousekeepingTaskType.values) {
      if (t.name == v) return libelleTypeMenage(t);
    }
    return 'Ménage';
  }
}

extension on String {
  String ifEmpty(String autre) => isEmpty ? autre : this;
}
