/// L'historique du centre de notifications : ce qui a sonne ces derniers
/// jours, et comment cela s'est termine.
///
/// Comme les alertes, il ne se stocke pas : chaque notification passee se
/// relit dans la ligne qui l'a fait naitre -- la commande en chambre, la
/// tache de menage, la panne, le transfert -- et son issue dans les memes
/// colonnes (livree a 10 h 40 par Paul, faite a 11 h 05 par Awa). Les
/// arrivees, les departs et les stocks bas sont des etats plutot que des
/// evenements : leur histoire est celle de la reception et des stocks, qui
/// ont chacune la leur.
///
/// Une seule requete, une `UNION ALL` des sources que l'agent a le droit de
/// voir : le flux suit les tables sans relecture en cascade.
library;

import 'package:drift/drift.dart';

import '../database.dart';
import '../enums.dart';
import 'alert_queries.dart';

/// Comment une notification passee s'est terminee.
enum IssueNotification {
  /// La situation dure : la commande est en route, la chambre pas faite.
  enCours,

  /// Quelqu'un l'a reglee : livree, faite, reparee, validee.
  reglee,

  /// Annulee ou refusee : il n'y a plus rien a faire.
  annulee,
}

class NotificationPassee {
  const NotificationPassee({
    required this.cle,
    required this.type,
    required this.moment,
    required this.titre,
    required this.detail,
    this.issue,
    this.libelleIssue,
    this.route,
  });

  final String cle;

  /// `null` pour un message du serveur, qui n'est pas un evenement d'alerte.
  final TypeEvenement? type;
  final DateTime moment;
  final String titre;
  final String detail;
  final IssueNotification? issue;

  /// « Livrée à 10 h 40 par Paul Nana », « Annulée : client endormi ».
  final String? libelleIssue;
  final String? route;
}

/// « 9 h 05 » : l'heure d'une notification, a la francaise.
String heureNotification(DateTime instant) {
  final h = instant.toLocal();
  return '${h.hour} h ${h.minute.toString().padLeft(2, '0')}';
}

extension HistoriqueNotificationsQueries on AtriumDatabase {
  /// Les notifications des [jours] derniers jours que cet agent aurait
  /// recues, les plus recentes d'abord.
  Stream<List<NotificationPassee>> watchHistoriqueNotifications(
    ContexteAlertes c, {
    int jours = 7,
  }) {
    final menage = c.accueil == '/menage';
    final branches = <String>[
      if (c.peut('order.read') || c.peut('room_order.create'))
        _commandes(rattacheSeulement: !c.peut('room_order.create')),
      if (TypeEvenement.chambreAFaire.concerne(c)) _menage(lesSiennes: menage),
      if (TypeEvenement.panne.concerne(c)) _pannes,
      if (TypeEvenement.transfertAValider.concerne(c)) _transferts,
      _messages,
    ];
    final depuis = c.maintenant.toUtc().subtract(Duration(days: jours));
    return customSelect(
      '''
      SELECT * FROM (${branches.join('\n UNION ALL\n')})
       ORDER BY moment DESC, id
       LIMIT 300
      ''',
      variables: [
        Variable<DateTime>(depuis),
        Variable<String>(c.agentId ?? ''),
      ],
      readsFrom: {
        orders,
        orderItems,
        outlets,
        rooms,
        users,
        userOutlets,
        housekeepingTasks,
        maintenanceTickets,
        stockMovements,
        stockLocations,
        products,
        notifications,
      },
    ).watch().map((lignes) => [for (final l in lignes) _lire(l)]);
  }

  // Chaque branche rend les memes colonnes, nommees dans chacune : une
  // `UNION` prend les noms de sa premiere branche, qui n'est pas toujours
  // la meme selon les droits de l'agent.

  /// Les commandes en chambre : toutes pour qui commande (la reception),
  /// celles de ses points de vente pour un agent qui y est rattache.
  static String _commandes({required bool rattacheSeulement}) =>
      '''
      SELECT 'COMMANDE' AS genre, o.id AS id, o.opened_at AS moment,
             r.number AS sujet, p.label AS lieu,
             (SELECT GROUP_CONCAT(i.quantity || ' × ' || i.label_snapshot,
                                  ', ')
                FROM order_items i
               WHERE i.order_id = o.id AND i.is_void = 0) AS detail,
             o.status AS statut,
             CASE o.status WHEN 'SERVED' THEN o.served_at
                           WHEN 'CANCELLED' THEN o.cancelled_at
                           WHEN 'IN_PREP' THEN o.taken_at END AS fin,
             TRIM(COALESCE(u.first_name, '') || ' ' ||
                  COALESCE(u.last_name, '')) AS par,
             o.total AS nombre, o.cancel_reason AS note
        FROM orders o
        LEFT JOIN rooms r   ON r.id = o.room_id
        LEFT JOIN outlets p ON p.id = o.outlet_id
        LEFT JOIN users u   ON u.id = CASE o.status
                                        WHEN 'SERVED' THEN o.delivered_by
                                        WHEN 'CANCELLED' THEN o.cancelled_by
                                        WHEN 'IN_PREP' THEN o.taken_by END
       WHERE o.type = 'ROOM_SERVICE' AND o.deleted_at IS NULL
         AND o.opened_at >= ?1
         ${rattacheSeulement ? '''
         AND (NOT EXISTS (SELECT 1 FROM user_outlets x WHERE x.user_id = ?2)
              OR o.outlet_id IN (SELECT outlet_id FROM user_outlets
                                  WHERE user_id = ?2))''' : ''}
      ''';

  /// Les chambres a faire ; pour une femme de chambre, les siennes et celles
  /// que personne n'avait encore prises, comme ses alertes.
  static String _menage({required bool lesSiennes}) =>
      '''
      SELECT 'MENAGE' AS genre, t.id AS id, t.created_at AS moment,
             r.number AS sujet, t.type AS lieu, t.priority AS detail,
             t.status AS statut,
             COALESCE(t.inspected_at, t.finished_at) AS fin,
             TRIM(COALESCE(u.first_name, '') || ' ' ||
                  COALESCE(u.last_name, '')) AS par,
             NULL AS nombre, NULL AS note
        FROM housekeeping_tasks t
        LEFT JOIN rooms r ON r.id = t.room_id
        LEFT JOIN users u ON u.id = t.assigned_to
       WHERE t.deleted_at IS NULL AND t.created_at >= ?1
         ${lesSiennes ? 'AND (t.assigned_to = ?2 OR t.assigned_to IS NULL)' : ''}
      ''';

  /// Les pannes hautes ou urgentes : les seules qui sonnent.
  static const _pannes = '''
      SELECT 'PANNE' AS genre, t.id AS id,
             COALESCE(t.reported_at, t.created_at) AS moment,
             r.number AS sujet, t.location AS lieu, t.title AS detail,
             t.status AS statut,
             COALESCE(t.resolved_at, t.closed_at) AS fin,
             TRIM(COALESCE(u.first_name, '') || ' ' ||
                  COALESCE(u.last_name, '')) AS par,
             NULL AS nombre, t.priority AS note
        FROM maintenance_tickets t
        LEFT JOIN rooms r ON r.id = t.room_id
        LEFT JOIN users u ON u.id = t.assigned_to
       WHERE t.deleted_at IS NULL AND t.priority IN ('HIGH','URGENT')
         AND COALESCE(t.reported_at, t.created_at) >= ?1
      ''';

  static const _transferts = '''
      SELECT 'TRANSFERT' AS genre, m.id AS id,
             COALESCE(m.moved_at, m.created_at) AS moment,
             p.label AS sujet, src.label AS lieu, dst.label AS detail,
             m.status AS statut, m.decided_at AS fin,
             TRIM(COALESCE(u.first_name, '') || ' ' ||
                  COALESCE(u.last_name, '')) AS par,
             m.quantity AS nombre, m.decision_note AS note
        FROM stock_movements m
        JOIN products p          ON p.id = m.product_id
        JOIN stock_locations src ON src.id = m.stock_location_id
        LEFT JOIN stock_locations dst ON dst.id = m.counterpart_location_id
        LEFT JOIN users u ON u.id = m.decided_by
       WHERE m.deleted_at IS NULL AND m.type = 'TRANSFER'
         AND COALESCE(m.moved_at, m.created_at) >= ?1
      ''';

  /// Les messages que le serveur adresse a tous ou a cet agent.
  static const _messages = '''
      SELECT 'MESSAGE' AS genre, n.id AS id, n.created_at AS moment,
             n.title AS sujet, NULL AS lieu, n.body AS detail,
             CASE n.is_read WHEN 1 THEN 'READ' ELSE 'UNREAD' END AS statut,
             n.read_at AS fin, NULL AS par, NULL AS nombre,
             n.severity AS note
        FROM notifications n
       WHERE n.deleted_at IS NULL AND n.created_at >= ?1
         AND (n.target_user_id IS NULL OR n.target_user_id = ?2)
      ''';

  static NotificationPassee _lire(QueryRow l) {
    final genre = l.read<String>('genre');
    final id = l.read<String>('id');
    final moment = l.read<DateTime>('moment');
    final sujet = l.readNullable<String>('sujet');
    final lieu = l.readNullable<String>('lieu');
    final detail = l.readNullable<String>('detail');
    final statut = l.readNullable<String>('statut');
    final fin = l.readNullable<DateTime>('fin');
    final par = switch (l.readNullable<String>('par')) {
      final p? when p.isNotEmpty => ' par $p',
      _ => '',
    };
    final a = fin == null ? '' : ' à ${heureNotification(fin)}';
    final note = l.readNullable<String>('note');

    switch (genre) {
      case 'COMMANDE':
        return NotificationPassee(
          cle: 'commande-$id',
          type: TypeEvenement.commandeChambre,
          moment: moment,
          titre: 'Commande en chambre : chambre ${sujet ?? '?'}',
          detail: [
            ?detail,
            if (lieu != null) 'pour $lieu',
          ].join(' '),
          issue: switch (statut) {
            'SERVED' => IssueNotification.reglee,
            'CANCELLED' => IssueNotification.annulee,
            _ => IssueNotification.enCours,
          },
          libelleIssue: switch (statut) {
            'SERVED' => 'Livrée$a$par',
            'CANCELLED' =>
              'Annulée$a$par${note == null ? '' : ' : $note'}',
            'IN_PREP' => 'Prise en charge$a$par',
            _ => 'En attente du point de vente',
          },
          route: routeCentreNotifications,
        );
      case 'MENAGE':
        final faite = statut == 'DONE' || statut == 'INSPECTED';
        return NotificationPassee(
          cle: 'menage-$id',
          type: TypeEvenement.chambreAFaire,
          moment: moment,
          titre: 'Chambre ${sujet ?? '?'} à faire',
          detail: [
            for (final t in HousekeepingTaskType.values)
              if (t.name == lieu) libelleTypeMenage(t),
            if (detail == 'URGENT')
              'client en attente'
            else if (detail == 'HIGH')
              'priorité haute',
          ].join(', '),
          issue: faite
              ? IssueNotification.reglee
              : statut == 'CANCELLED'
              ? IssueNotification.annulee
              : IssueNotification.enCours,
          libelleIssue: faite
              ? '${statut == 'INSPECTED' ? 'Contrôlée' : 'Faite'}$a$par'
              : switch (statut) {
                  'CANCELLED' => 'Annulée',
                  'IN_PROGRESS' => 'En cours$par',
                  'ASSIGNED' => 'Confiée$par',
                  _ => 'À faire',
                },
          route: '/menage',
        );
      case 'PANNE':
        final reglee = statut == 'RESOLVED' || statut == 'CLOSED';
        return NotificationPassee(
          cle: 'panne-$id',
          type: TypeEvenement.panne,
          moment: moment,
          titre: note == 'URGENT'
              ? 'Panne urgente : ${detail ?? ''}'
              : 'Panne prioritaire : ${detail ?? ''}',
          detail: sujet != null ? 'Chambre $sujet' : lieu ?? 'Lieu non précisé',
          issue: reglee
              ? IssueNotification.reglee
              : statut == 'CANCELLED'
              ? IssueNotification.annulee
              : IssueNotification.enCours,
          libelleIssue: reglee
              ? 'Réparée$a$par'
              : switch (statut) {
                  'CANCELLED' => 'Annulée',
                  'IN_PROGRESS' => 'En réparation$par',
                  'ASSIGNED' => 'Confiée$par',
                  _ => 'Signalée, pas encore prise',
                },
          route: '/maintenance',
        );
      case 'TRANSFERT':
        return NotificationPassee(
          cle: 'transfert-$id',
          type: TypeEvenement.transfertAValider,
          moment: moment,
          titre: 'Transfert : ${l.readNullable<int>('nombre') ?? 0} ${sujet ?? ''}',
          detail: 'De « ${lieu ?? '?'} » vers « ${detail ?? '?'} »',
          issue: switch (statut) {
            'APPROVED' => IssueNotification.reglee,
            'REJECTED' => IssueNotification.annulee,
            _ => IssueNotification.enCours,
          },
          libelleIssue: switch (statut) {
            'APPROVED' => 'Validé$a$par',
            'REJECTED' => 'Refusé$a$par${note == null ? '' : ' : $note'}',
            _ => 'À valider',
          },
          route: '/stocks',
        );
      default:
        return NotificationPassee(
          cle: 'message-$id',
          type: null,
          moment: moment,
          titre: sujet ?? 'Message',
          detail: detail ?? '',
        );
    }
  }
}
