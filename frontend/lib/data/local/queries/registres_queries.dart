/// Les registres des rapports par module (F3.3, demande du 19 octobre) :
/// le detail ligne par ligne qui accompagne les chiffres, comme dans un
/// document administratif -- chaque sejour, chaque vente, chaque mouvement
/// de stock, chaque chambre faite, chaque panne.
///
/// Memes filtres que le rapport financier, memes variables : ?1 et ?2 les
/// journees hotelieres de debut et de fin, ?3 le point de vente, ?4 l'agent,
/// ?5 le type de chambre (`FiltresRapport.variables`). Les instants (une
/// panne signalee, un mouvement) se bornent a l'heure de bascule de la
/// journee : ?7 et ?8.
///
/// Les mouvements de stock, les taches de menage et les pannes ne
/// descendent pas du serveur : leurs registres montrent ce que cette
/// tablette a enregistre.
library;

import 'package:drift/drift.dart';

import '../../../core/business_day.dart' show heureBasculeParDefaut;
import '../database.dart';
import '../enums.dart';
import 'report_queries.dart' show FiltresRapport;

/// Un sejour du registre de la reception.
typedef LigneSejour = ({
  String chambre,
  String client,
  String categorie,
  DateTime arrivee,
  DateTime depart,
  int nuits,
  int tarif,
  ReservationStatus statut,
});

/// Une vente : une ardoise servie a un comptoir dans la journee.
typedef LigneVente = ({
  DateTime jour,
  DateTime? moment,
  String pointDeVente,
  String client,
  String articles,
  int montant,

  /// « Payée », « À payer », « Sur la chambre ».
  String reglement,
  String? agent,
});

/// Un article vendu sur la periode.
typedef LigneArticle = ({String article, int quantite, int montant});

/// Un mouvement de stock.
typedef LigneMouvementStock = ({
  DateTime? moment,
  StockMovementType type,
  StockMovementStatus statut,
  String produit,
  String unite,
  String magasin,
  String? vers,
  int quantite,
  String? motif,
  String? agent,
});

/// Une tache de menage.
typedef TacheRegistre = ({
  DateTime jour,
  String chambre,
  HousekeepingTaskType type,
  TaskStatus statut,
  String? agent,
  DateTime? debut,
  DateTime? fin,
  int? duree,
});

/// Une panne.
typedef LignePanne = ({
  String numero,
  DateTime? signalee,
  String lieu,
  String titre,
  Priority priorite,
  TicketStatus statut,
  DateTime? reglee,
  int cout,
});

extension RegistresQueries on AtriumDatabase {
  /// Les variables du rapport, puis les deux instants qui bornent la
  /// periode (?7 et ?8).
  List<Variable<Object>> _avecInstants(FiltresRapport f) {
    final debut = DateTime(f.du.year, f.du.month, f.du.day, heureBasculeParDefaut);
    final fin = DateTime(
      f.au.year,
      f.au.month,
      f.au.day + 1,
      heureBasculeParDefaut,
    );
    return [
      ...f.variables(6),
      Variable<DateTime>(debut.toUtc()),
      Variable<DateTime>(fin.toUtc()),
    ];
  }

  static String? _nom(QueryRow r, String prenom, String nom) {
    final n =
        '${r.readNullable<String>(prenom) ?? ''} '
                '${r.readNullable<String>(nom) ?? ''}'
            .trim();
    return n.isEmpty ? null : n;
  }

  /// Les sejours qui touchent la periode : arrives avant sa fin, partis
  /// apres son debut. Les reservations annulees ou sans chambre n'y sont
  /// pas : elles ne sont pas des sejours.
  Future<List<LigneSejour>> registreSejours(FiltresRapport f) async {
    final rangs = await customSelect(
      '''
      SELECT rm.number AS chambre, rt.label AS categorie,
             rr.arrival_date, rr.departure_date, rr.nightly_rate,
             rr.status, g.first_name, g.last_name
        FROM reservation_rooms rr
        JOIN reservations r ON r.id = rr.reservation_id
        JOIN room_types rt  ON rt.id = rr.room_type_id
        LEFT JOIN rooms rm  ON rm.id = rr.room_id
        LEFT JOIN guests g  ON g.id = r.guest_id
       WHERE rr.deleted_at IS NULL
         AND rr.status IN ('CHECKED_IN', 'CHECKED_OUT')
         AND rr.arrival_date <= ?2
         AND rr.departure_date > ?1
         AND (?4 IS NULL OR rr.checked_in_by = ?4 OR rr.checked_out_by = ?4)
         AND (?5 IS NULL OR rr.room_type_id = ?5)
       ORDER BY rr.arrival_date, rm.number
      ''',
      variables: f.variables(5),
      readsFrom: {reservationRooms, reservations, roomTypes, rooms, guests},
    ).get();
    return [
      for (final r in rangs)
        () {
          final arrivee = DateTime.parse(r.read<String>('arrival_date'));
          final depart = DateTime.parse(r.read<String>('departure_date'));
          return (
            chambre: r.readNullable<String>('chambre') ?? '—',
            client: _nom(r, 'first_name', 'last_name') ?? 'Client',
            categorie: r.read<String>('categorie'),
            arrivee: arrivee,
            depart: depart,
            nuits: depart.difference(arrivee).inDays.clamp(0, 9999),
            tarif: r.read<int>('nightly_rate'),
            statut: ReservationStatus.values.byName(r.read<String>('status')),
          );
        }(),
    ];
  }

  /// Les ventes des points de vente, une ardoise par journee, dans l'ordre.
  Future<List<LigneVente>> journalVentes(FiltresRapport f) async {
    final rangs = await customSelect(
      '''
      SELECT v.*, u.first_name AS agent_prenom, u.last_name AS agent_nom
        FROM (
          SELECT f.type, f.status, f.tab_number, f.tab_label,
                 fi.business_date AS jour,
                 o.label AS point_de_vente,
                 g.first_name, g.last_name,
                 (SELECT rm.number FROM reservation_rooms rr
                    JOIN rooms rm ON rm.id = rr.room_id
                   WHERE rr.id = f.reservation_room_id) AS chambre,
                 SUM(fi.amount) AS montant,
                 MAX(COALESCE(fi.posted_at, fi.created_at)) AS moment,
                 MAX(fi.posted_by) AS agent_id,
                 GROUP_CONCAT(
                   CASE WHEN fi.quantity > 1
                        THEN fi.quantity || ' × ' || fi.label
                        ELSE fi.label END, ', ') AS articles
            FROM folio_items fi
            JOIN folios f       ON f.id = fi.folio_id
            JOIN outlets o      ON o.id = fi.source_id
            LEFT JOIN guests g  ON g.id = f.guest_id
           WHERE fi.deleted_at IS NULL
             AND fi.is_void = 0
             AND fi.source_table = 'outlets'
             AND fi.business_date BETWEEN ?1 AND ?2
             AND (?3 IS NULL OR fi.source_id = ?3)
             AND (?4 IS NULL OR fi.posted_by = ?4)
           GROUP BY f.id, fi.business_date, fi.source_id
        ) v
        LEFT JOIN users u ON u.id = v.agent_id
       ORDER BY v.jour, v.moment
      ''',
      variables: f.variables(4),
      readsFrom: {folioItems, folios, outlets, guests, reservationRooms, rooms, users},
    ).get();
    return [
      for (final r in rangs)
        () {
          final client = _nom(r, 'first_name', 'last_name');
          final chambre = r.readNullable<String>('chambre');
          final numero = r.readNullable<int>('tab_number');
          return (
            jour: DateTime.parse(r.read<String>('jour')),
            moment: r.readNullable<DateTime>('moment'),
            pointDeVente: r.read<String>('point_de_vente'),
            client: chambre != null
                ? 'Chambre $chambre${client == null ? '' : ', $client'}'
                : client ??
                      r.readNullable<String>('tab_label') ??
                      (numero == null
                          ? 'Client divers'
                          : 'Client divers n°$numero'),
            articles: r.readNullable<String>('articles') ?? '',
            montant: r.read<int>('montant'),
            reglement: r.read<String>('type') != 'WALK_IN'
                ? 'Sur la chambre'
                : r.read<String>('status') == 'OPEN'
                ? 'À payer'
                : 'Payée',
            agent: _nom(r, 'agent_prenom', 'agent_nom'),
          );
        }(),
    ];
  }

  /// Ce qui s'est vendu, article par article, le plus gros montant d'abord.
  Future<List<LigneArticle>> ventesParArticle(FiltresRapport f) async {
    final rangs = await customSelect(
      '''
      SELECT fi.label AS article,
             COALESCE(SUM(fi.quantity), 0) AS quantite,
             COALESCE(SUM(fi.amount), 0)   AS montant
        FROM folio_items fi
       WHERE fi.deleted_at IS NULL
         AND fi.is_void = 0
         AND fi.source_table = 'outlets'
         AND fi.business_date BETWEEN ?1 AND ?2
         AND (?3 IS NULL OR fi.source_id = ?3)
         AND (?4 IS NULL OR fi.posted_by = ?4)
       GROUP BY fi.label
       ORDER BY montant DESC, quantite DESC, article
      ''',
      variables: f.variables(4),
      readsFrom: {folioItems},
    ).get();
    return [
      for (final r in rangs)
        (
          article: r.read<String>('article'),
          quantite: r.read<int>('quantite'),
          montant: r.read<int>('montant'),
        ),
    ];
  }

  /// Les mouvements de stock de la periode, dans l'ordre. Le point de vente
  /// retient ses magasins ; l'agent, ce qu'il a saisi.
  Future<List<LigneMouvementStock>> mouvementsStock(FiltresRapport f) async {
    final rangs = await customSelect(
      '''
      SELECT m.type, m.status, m.quantity, m.reason,
             COALESCE(m.moved_at, m.created_at) AS moment,
             p.label AS produit, p.unit,
             l.label AS magasin, c.label AS vers,
             u.first_name AS agent_prenom, u.last_name AS agent_nom
        FROM stock_movements m
        JOIN products p        ON p.id = m.product_id
        JOIN stock_locations l ON l.id = m.stock_location_id
        LEFT JOIN stock_locations c ON c.id = m.counterpart_location_id
        LEFT JOIN users u ON u.id = m.moved_by
       WHERE m.deleted_at IS NULL
         AND COALESCE(m.moved_at, m.created_at) >= ?7
         AND COALESCE(m.moved_at, m.created_at) < ?8
         AND (?3 IS NULL OR l.outlet_id = ?3 OR c.outlet_id = ?3)
         AND (?4 IS NULL OR m.moved_by = ?4)
       ORDER BY moment
      ''',
      variables: _avecInstants(f),
      readsFrom: {stockMovements, products, stockLocations, users},
    ).get();
    return [
      for (final r in rangs)
        (
          moment: r.readNullable<DateTime>('moment'),
          type: StockMovementType.values.byName(r.read<String>('type')),
          statut: StockMovementStatus.values.byName(r.read<String>('status')),
          produit: r.read<String>('produit'),
          unite: r.read<String>('unit'),
          magasin: r.read<String>('magasin'),
          vers: r.readNullable<String>('vers'),
          quantite: r.read<int>('quantity'),
          motif: r.readNullable<String>('reason'),
          agent: _nom(r, 'agent_prenom', 'agent_nom'),
        ),
    ];
  }

  /// Les taches de menage des journees de la periode, dans l'ordre.
  Future<List<TacheRegistre>> registreMenage(FiltresRapport f) async {
    final rangs = await customSelect(
      '''
      SELECT t.business_date, t.type, t.status, t.started_at, t.finished_at,
             t.duration_minutes, rm.number AS chambre,
             u.first_name AS agent_prenom, u.last_name AS agent_nom
        FROM housekeeping_tasks t
        JOIN rooms rm ON rm.id = t.room_id
        LEFT JOIN users u ON u.id = t.assigned_to
       WHERE t.deleted_at IS NULL
         AND t.business_date BETWEEN ?1 AND ?2
         AND (?4 IS NULL OR t.assigned_to = ?4)
         AND (?5 IS NULL OR rm.room_type_id = ?5)
       ORDER BY t.business_date, COALESCE(t.finished_at, t.started_at,
                                          t.created_at)
      ''',
      variables: f.variables(5),
      readsFrom: {housekeepingTasks, rooms, users},
    ).get();
    return [
      for (final r in rangs)
        (
          jour: DateTime.parse(r.read<String>('business_date')),
          chambre: r.read<String>('chambre'),
          type: HousekeepingTaskType.values.byName(r.read<String>('type')),
          statut: TaskStatus.values.byName(r.read<String>('status')),
          agent: _nom(r, 'agent_prenom', 'agent_nom'),
          debut: r.readNullable<DateTime>('started_at'),
          fin: r.readNullable<DateTime>('finished_at'),
          duree: r.readNullable<int>('duration_minutes'),
        ),
    ];
  }

  /// Les pannes signalees ou reglees sur la periode, dans l'ordre.
  Future<List<LignePanne>> registrePannes(FiltresRapport f) async {
    final rangs = await customSelect(
      '''
      SELECT m.number, m.title, m.location, m.priority, m.status,
             m.reported_at, m.resolved_at, m.cost, rm.number AS chambre
        FROM maintenance_tickets m
        LEFT JOIN rooms rm ON rm.id = m.room_id
       WHERE m.deleted_at IS NULL
         AND ((COALESCE(m.reported_at, m.created_at) >= ?7
               AND COALESCE(m.reported_at, m.created_at) < ?8)
              OR (m.resolved_at >= ?7 AND m.resolved_at < ?8))
         AND (?4 IS NULL OR m.assigned_to = ?4 OR m.reported_by = ?4)
         AND (?5 IS NULL OR rm.room_type_id = ?5)
       ORDER BY COALESCE(m.reported_at, m.created_at)
      ''',
      variables: _avecInstants(f),
      readsFrom: {maintenanceTickets, rooms},
    ).get();
    return [
      for (final r in rangs)
        (
          numero: r.read<String>('number'),
          signalee: r.readNullable<DateTime>('reported_at'),
          lieu: switch (r.readNullable<String>('chambre')) {
            final c? => 'Chambre $c',
            null => r.readNullable<String>('location') ?? '—',
          },
          titre: r.read<String>('title'),
          priorite: Priority.values.byName(r.read<String>('priority')),
          statut: TicketStatus.values.byName(r.read<String>('status')),
          reglee: r.readNullable<DateTime>('resolved_at'),
          cout: r.read<int>('cost'),
        ),
    ];
  }
}
