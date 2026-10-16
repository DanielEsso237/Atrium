/// Les mouvements de l'hotel et le parcours de ses clients (16 octobre).
///
/// Trois lectures, toutes sur la base locale, donc instantanees et hors
/// ligne :
///
/// - la **chronologie** : arrivees, departs, reservations prises ou annulees,
///   encaissements et leurs annulations, dans l'ordre ou ils ont eu lieu ;
/// - les **clients deja venus** : ceux qui ont dormi au moins une fois, avec
///   ce qu'ils ont consomme et paye ;
/// - le **parcours d'un client** : chacun de ses sejours et ardoises, ligne
///   par ligne.
library;

import 'package:drift/drift.dart';

import '../database.dart';
import '../enums.dart';

/// La nature d'un mouvement.
enum GenreMouvement {
  arrivee('Arrivée'),
  depart('Départ'),
  reservation('Réservation'),
  annulation('Annulation'),
  encaissement('Encaissement'),
  remboursement('Encaissement annulé');

  const GenreMouvement(this.libelle);
  final String libelle;
}

/// Un evenement de la chronologie.
class Mouvement {
  const Mouvement({
    required this.genre,
    required this.moment,
    this.client,
    this.guestId,
    this.chambre,
    this.reference,
    this.montant,
    this.moyen,
    this.detail,
    this.agent,
    this.lineId,
    this.paymentId,
    this.annulable = false,
  });

  final GenreMouvement genre;
  final DateTime moment;
  final String? client;
  final String? guestId;
  final String? chambre;
  final String? reference;

  /// En francs CFA entiers ; pour les encaissements.
  final int? montant;

  /// Le moyen d'un encaissement.
  final PaymentMethod? moyen;

  /// Ce qui complete la ligne : moyen de paiement, dates du sejour, motif.
  final String? detail;
  final String? agent;

  /// La ligne de sejour d'une arrivee ou d'un depart.
  final String? lineId;
  final String? paymentId;

  /// Le mouvement peut encore etre defait : l'arrivee d'un client toujours
  /// la, le depart d'un client toujours parti, un encaissement pas encore
  /// annule.
  final bool annulable;
}

/// Un client qui a deja dormi a l'hotel.
class ClientVenu {
  const ClientVenu({
    required this.guestId,
    required this.nom,
    required this.code,
    required this.sejours,
    required this.nuits,
    required this.consomme,
    required this.paye,
    required this.derniereVisite,
    this.telephone,
    this.nationalite,
    this.vip = false,
    this.enCeMoment = false,
  });

  final String guestId;
  final String nom;
  final String code;
  final String? telephone;
  final String? nationalite;
  final bool vip;
  final int sejours;
  final int nuits;

  /// Tout ce qui a ete porte sur ses ardoises, chambre et comptoirs.
  final int consomme;
  final int paye;
  final DateTime? derniereVisite;

  /// Il est a l'hotel en ce moment.
  final bool enCeMoment;

  int get solde => consomme - paye;
}

/// Une ligne d'ardoise, telle que le client la retrouverait sur sa facture.
class LigneParcours {
  const LigneParcours({
    required this.libelle,
    required this.categorie,
    required this.quantite,
    required this.montant,
    required this.journee,
    this.pointDeVente,
    this.annulee = false,
  });

  final String libelle;
  final ChargeCategory categorie;
  final int quantite;
  final int montant;
  final String journee;
  final String? pointDeVente;
  final bool annulee;
}

/// Un paiement d'une ardoise.
class PaiementParcours {
  const PaiementParcours({
    required this.id,
    required this.moyen,
    required this.montant,
    required this.remboursement,
    required this.annule,
    this.moment,
  });

  final String id;
  final PaymentMethod moyen;
  final int montant;
  final bool remboursement;
  final bool annule;
  final DateTime? moment;
}

/// Un sejour, ou une ardoise du comptoir, du parcours d'un client.
class EtapeParcours {
  const EtapeParcours({
    required this.folioId,
    required this.titre,
    required this.lignes,
    required this.paiements,
    required this.consomme,
    required this.paye,
    this.lineId,
    this.reference,
    this.chambre,
    this.categorie,
    this.arrivee,
    this.depart,
    this.arriveLe,
    this.partiLe,
    this.statut,
  });

  final String? folioId;
  final String titre;
  final String? lineId;
  final String? reference;
  final String? chambre;
  final String? categorie;

  /// Dates seules, `AAAA-MM-JJ`.
  final String? arrivee;
  final String? depart;
  final DateTime? arriveLe;
  final DateTime? partiLe;
  final ReservationStatus? statut;
  final List<LigneParcours> lignes;
  final List<PaiementParcours> paiements;
  final int consomme;
  final int paye;

  int get solde => consomme - paye;

  /// Le moment qui ordonne le parcours, le plus recent d'abord.
  DateTime? get repere => arriveLe ?? partiLe;
}

String? _nom(String? prenom, String? nom) {
  final complet = [
    prenom?.trim(),
    nom?.trim(),
  ].whereType<String>().where((p) => p.isNotEmpty).join(' ');
  return complet.isEmpty ? null : complet;
}

extension MouvementsQueries on AtriumDatabase {
  /// La chronologie, la plus recente d'abord, a partir de [depuis] (un
  /// instant UTC) ; tout l'historique si `null`.
  Stream<List<Mouvement>> watchMouvements({
    DateTime? depuis,
    int limite = 400,
    String? guestId,
  }) {
    final borne = (depuis ?? DateTime.utc(2000)).toUtc().toIso8601String();
    return customSelect(
      '''
      SELECT * FROM (
        SELECT 'arrivee' AS genre, rr.checked_in_at AS moment,
               g.first_name AS prenom, g.last_name AS nom, g.id AS guest_id,
               rm.number AS chambre, r.reference AS reference,
               NULL AS montant,
               CASE WHEN rr.is_walk_in = 1 THEN 'Arrivée directe'
                    ELSE rt.label END AS detail,
               u.first_name AS a_prenom, u.last_name AS a_nom,
               rr.id AS line_id, NULL AS payment_id,
               CASE WHEN rr.status = 'CHECKED_IN' THEN 1 ELSE 0 END AS annulable
          FROM reservation_rooms rr
          JOIN reservations r ON r.id = rr.reservation_id
          LEFT JOIN guests g ON g.id = r.guest_id
          LEFT JOIN rooms rm ON rm.id = rr.room_id
          LEFT JOIN room_types rt ON rt.id = rr.room_type_id
          LEFT JOIN users u ON u.id = rr.checked_in_by
         WHERE rr.deleted_at IS NULL AND rr.checked_in_at IS NOT NULL
           AND julianday(rr.checked_in_at) >= julianday(?1)

        UNION ALL
        SELECT 'depart', rr.checked_out_at,
               g.first_name, g.last_name, g.id,
               rm.number, r.reference, NULL, rt.label,
               u.first_name, u.last_name,
               rr.id, NULL,
               CASE WHEN rr.status = 'CHECKED_OUT' THEN 1 ELSE 0 END
          FROM reservation_rooms rr
          JOIN reservations r ON r.id = rr.reservation_id
          LEFT JOIN guests g ON g.id = r.guest_id
          LEFT JOIN rooms rm ON rm.id = rr.room_id
          LEFT JOIN room_types rt ON rt.id = rr.room_type_id
          LEFT JOIN users u ON u.id = rr.checked_out_by
         WHERE rr.deleted_at IS NULL AND rr.checked_out_at IS NOT NULL
           AND julianday(rr.checked_out_at) >= julianday(?1)

        UNION ALL
        -- Une arrivee directe n'est pas une reservation prise. Reconnue a
        -- sa ligne et non a `source` : la tablette pose WALK_IN sur tous
        -- les dossiers qu'elle cree.
        SELECT 'reservation', r.created_at,
               g.first_name, g.last_name, g.id,
               NULL, r.reference, NULL,
               'du ' || r.arrival_date || ' au ' || r.departure_date,
               NULL, NULL, NULL, NULL, 0
          FROM reservations r
          LEFT JOIN guests g ON g.id = r.guest_id
         WHERE r.deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM reservation_rooms w
                            WHERE w.reservation_id = r.id
                              AND w.is_walk_in = 1)
           AND julianday(r.created_at) >= julianday(?1)

        UNION ALL
        SELECT 'annulation', r.cancelled_at,
               g.first_name, g.last_name, g.id,
               NULL, r.reference, NULL, r.cancel_reason,
               NULL, NULL, NULL, NULL, 0
          FROM reservations r
          LEFT JOIN guests g ON g.id = r.guest_id
         WHERE r.deleted_at IS NULL AND r.cancelled_at IS NOT NULL
           AND julianday(r.cancelled_at) >= julianday(?1)

        UNION ALL
        SELECT CASE WHEN p.is_refund = 1 THEN 'remboursement'
                    ELSE 'encaissement' END,
               p.received_at,
               COALESCE(g.first_name, g2.first_name),
               COALESCE(g.last_name, g2.last_name),
               COALESCE(g.id, g2.id),
               rm.number, f.number, p.amount,
               CASE WHEN p.is_refund = 1 THEN COALESCE(p.notes, p.method)
                    ELSE p.method END,
               u.first_name, u.last_name,
               NULL, p.id,
               CASE WHEN p.is_refund = 0 AND p.folio_id IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM payments x
                                      WHERE x.reverses_payment_id = p.id
                                        AND x.deleted_at IS NULL)
                    THEN 1 ELSE 0 END
          FROM payments p
          LEFT JOIN folios f ON f.id = p.folio_id
          LEFT JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
          LEFT JOIN reservations r ON r.id = rr.reservation_id
          LEFT JOIN guests g ON g.id = COALESCE(f.guest_id, r.guest_id)
          LEFT JOIN guests g2 ON g2.id = (
                SELECT r2.guest_id FROM reservations r2
                 WHERE p.folio_id IS NULL
                   AND p.notes = 'Arrhes ' || r2.reference)
          LEFT JOIN rooms rm ON rm.id = rr.room_id
          LEFT JOIN users u ON u.id = p.received_by
         WHERE p.deleted_at IS NULL AND p.received_at IS NOT NULL
           AND julianday(p.received_at) >= julianday(?1)
      )
      WHERE moment IS NOT NULL
        AND (?3 IS NULL OR guest_id = ?3)
      ORDER BY julianday(moment) DESC
      LIMIT ?2
      ''',
      variables: [
        Variable.withString(borne),
        Variable.withInt(limite),
        Variable(guestId),
      ],
      readsFrom: {
        reservations,
        reservationRooms,
        guests,
        rooms,
        roomTypes,
        users,
        payments,
        folios,
      },
    ).watch().map(
      (lignes) => [
        for (final l in lignes)
          Mouvement(
            genre: GenreMouvement.values.byName(l.read<String>('genre')),
            moment: l.read<DateTime>('moment'),
            client: _nom(
              l.readNullable<String>('prenom'),
              l.readNullable<String>('nom'),
            ),
            guestId: l.readNullable<String>('guest_id'),
            chambre: l.readNullable<String>('chambre'),
            reference: l.readNullable<String>('reference'),
            montant: l.readNullable<int>('montant'),
            moyen: l.read<String>('genre') == 'encaissement'
                ? PaymentMethod.values.asNameMap()[l.readNullable<String>(
                    'detail',
                  )]
                : null,
            detail: l.read<String>('genre') == 'encaissement'
                ? null
                : l.readNullable<String>('detail'),
            agent: _nom(
              l.readNullable<String>('a_prenom'),
              l.readNullable<String>('a_nom'),
            ),
            lineId: l.readNullable<String>('line_id'),
            paymentId: l.readNullable<String>('payment_id'),
            annulable: l.read<int>('annulable') == 1,
          ),
      ],
    );
  }

  /// Les clients qui ont dormi au moins une fois, le plus recent d'abord.
  Stream<List<ClientVenu>> watchClientsVenus() {
    return customSelect(
      '''
      WITH sejours AS (
        SELECT r.guest_id, rr.id AS line_id, rr.status, rr.checked_in_at,
               rr.is_walk_in, rr.stay_unit,
               MAX(0, CAST(julianday(rr.departure_date)
                           - julianday(rr.arrival_date) AS INTEGER)) AS nuits
          FROM reservation_rooms rr
          JOIN reservations r ON r.id = rr.reservation_id
         WHERE rr.deleted_at IS NULL AND rr.checked_in_at IS NOT NULL
      ),
      ardoises AS (
        SELECT f.id, COALESCE(f.guest_id, r.guest_id) AS guest_id,
               f.charges_total, f.payments_total
          FROM folios f
          LEFT JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
          LEFT JOIN reservations r ON r.id = rr.reservation_id
         WHERE f.deleted_at IS NULL
      )
      SELECT g.id, g.first_name, g.last_name, g.code, g.phone,
             g.nationality, g.is_vip,
             COUNT(s.line_id) AS sejours,
             SUM(CASE WHEN s.stay_unit = 'HOURS' THEN 0 ELSE s.nuits END)
               AS nuits,
             MAX(s.checked_in_at) AS derniere,
             MAX(CASE WHEN s.status = 'CHECKED_IN' THEN 1 ELSE 0 END)
               AS present,
             COALESCE((SELECT SUM(a.charges_total) FROM ardoises a
                        WHERE a.guest_id = g.id), 0) AS consomme,
             COALESCE((SELECT SUM(a.payments_total) FROM ardoises a
                        WHERE a.guest_id = g.id), 0) AS paye
        FROM guests g
        JOIN sejours s ON s.guest_id = g.id
       WHERE g.deleted_at IS NULL
       GROUP BY g.id
       ORDER BY julianday(MAX(s.checked_in_at)) DESC
      ''',
      readsFrom: {guests, reservations, reservationRooms, folios},
    ).watch().map(
      (lignes) => [
        for (final l in lignes)
          ClientVenu(
            guestId: l.read<String>('id'),
            nom:
                _nom(
                  l.readNullable<String>('first_name'),
                  l.readNullable<String>('last_name'),
                ) ??
                'Client',
            code: l.read<String>('code'),
            telephone: l.readNullable<String>('phone'),
            nationalite: l.readNullable<String>('nationality'),
            vip: l.read<bool>('is_vip'),
            sejours: l.read<int>('sejours'),
            nuits: l.readNullable<int>('nuits') ?? 0,
            derniereVisite: l.readNullable<DateTime>('derniere'),
            enCeMoment: l.read<int>('present') == 1,
            consomme: l.read<int>('consomme'),
            paye: l.read<int>('paye'),
          ),
      ],
    );
  }

  /// Le parcours d'un client : ses sejours et ses ardoises du comptoir, le
  /// plus recent d'abord, chacun avec ses lignes et ses paiements.
  Stream<List<EtapeParcours>> watchParcoursClient(String guestId) {
    return customSelect(
      '''
      SELECT f.id AS folio_id, rr.id AS line_id, r.reference, rm.number,
             rt.label AS categorie, rr.arrival_date, rr.departure_date,
             rr.checked_in_at, rr.checked_out_at, rr.status, rr.is_walk_in,
             f.charges_total, f.payments_total, f.opened_at, f.closed_at,
             o.label AS comptoir, f.tab_label, f.tab_number
        FROM folios f
        LEFT JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
        LEFT JOIN reservations r ON r.id = rr.reservation_id
        LEFT JOIN rooms rm ON rm.id = rr.room_id
        LEFT JOIN room_types rt ON rt.id = rr.room_type_id
        LEFT JOIN outlets o ON o.id = f.outlet_id
       WHERE f.deleted_at IS NULL
         AND COALESCE(f.guest_id, r.guest_id) = ?1
      ORDER BY julianday(COALESCE(rr.checked_in_at, f.opened_at, f.created_at))
               DESC
      ''',
      variables: [Variable.withString(guestId)],
      readsFrom: {
        folios,
        reservationRooms,
        reservations,
        rooms,
        roomTypes,
        outlets,
        folioItems,
        payments,
      },
    ).watch().asyncMap((ardoises) async {
      final ids = [for (final a in ardoises) a.read<String>('folio_id')];
      if (ids.isEmpty) return const <EtapeParcours>[];
      final marques = List.filled(ids.length, '?').join(',');
      final lignes = await customSelect(
        '''
        SELECT i.folio_id, i.label, i.category, i.quantity, i.amount,
               i.business_date, i.is_void, o.label AS point_de_vente
          FROM folio_items i
          LEFT JOIN outlets o ON o.id = i.source_id
                             AND i.source_table = 'outlets'
         WHERE i.deleted_at IS NULL AND i.folio_id IN ($marques)
         ORDER BY i.business_date, julianday(i.posted_at)
        ''',
        variables: [for (final id in ids) Variable.withString(id)],
        readsFrom: {folioItems, outlets},
      ).get();
      final paiements = await customSelect(
        '''
        SELECT p.id, p.folio_id, p.method, p.amount, p.is_refund,
               p.received_at,
               EXISTS (SELECT 1 FROM payments x
                        WHERE x.reverses_payment_id = p.id
                          AND x.deleted_at IS NULL) AS annule
          FROM payments p
         WHERE p.deleted_at IS NULL AND p.folio_id IN ($marques)
         ORDER BY julianday(p.received_at)
        ''',
        variables: [for (final id in ids) Variable.withString(id)],
        readsFrom: {payments},
      ).get();

      return [
        for (final a in ardoises)
          () {
            final folioId = a.read<String>('folio_id');
            final comptoir = a.readNullable<String>('comptoir');
            final lineId = a.readNullable<String>('line_id');
            final statut = a.readNullable<String>('status');
            return EtapeParcours(
              folioId: folioId,
              lineId: lineId,
              titre: lineId != null
                  ? (a.read<bool>('is_walk_in')
                        ? 'Arrivée directe'
                        : 'Séjour ${a.readNullable<String>('reference') ?? ''}'
                              .trim())
                  : (a.readNullable<String>('tab_label') ??
                        (comptoir == null ? 'Ardoise' : 'Ardoise · $comptoir')),
              reference: a.readNullable<String>('reference'),
              chambre: a.readNullable<String>('number'),
              categorie: a.readNullable<String>('categorie'),
              arrivee: a.readNullable<String>('arrival_date'),
              depart: a.readNullable<String>('departure_date'),
              arriveLe:
                  a.readNullable<DateTime>('checked_in_at') ??
                  a.readNullable<DateTime>('opened_at'),
              partiLe:
                  a.readNullable<DateTime>('checked_out_at') ??
                  a.readNullable<DateTime>('closed_at'),
              statut: statut == null
                  ? null
                  : ReservationStatus.values.byName(statut),
              consomme: a.read<int>('charges_total'),
              paye: a.read<int>('payments_total'),
              lignes: [
                for (final l in lignes)
                  if (l.read<String>('folio_id') == folioId)
                    LigneParcours(
                      libelle: l.read<String>('label'),
                      categorie: ChargeCategory.values.byName(
                        l.read<String>('category'),
                      ),
                      quantite: l.read<int>('quantity'),
                      montant: l.read<int>('amount'),
                      journee: l.read<String>('business_date'),
                      pointDeVente: l.readNullable<String>('point_de_vente'),
                      annulee: l.read<bool>('is_void'),
                    ),
              ],
              paiements: [
                for (final p in paiements)
                  if (p.read<String>('folio_id') == folioId)
                    PaiementParcours(
                      id: p.read<String>('id'),
                      moyen: PaymentMethod.values.byName(
                        p.read<String>('method'),
                      ),
                      montant: p.read<int>('amount'),
                      remboursement: p.read<bool>('is_refund'),
                      annule: p.read<int>('annule') == 1,
                      moment: p.readNullable<DateTime>('received_at'),
                    ),
              ],
            );
          }(),
      ];
    });
  }

  /// Ce que le tableau de bord des mouvements ajoute a celui du jour : ce
  /// qui arrive dans les sept jours, ce qui a ete pris aujourd'hui, ce qui
  /// attend encore une chambre.
  ///
  /// [jour] est la journee hoteliere (`AAAA-MM-JJ`), [debut] l'instant ou
  /// elle a commence : une reservation prise a une heure du matin compte
  /// pour la veille, comme partout.
  Stream<ResumeMouvements> watchResumeMouvements(String jour, DateTime debut) {
    return customSelect(
      '''
      SELECT
        (SELECT COUNT(*) FROM reservation_rooms rr
          WHERE rr.deleted_at IS NULL
            AND rr.status IN ('PENDING', 'CONFIRMED')
            AND rr.arrival_date > ?1
            AND rr.arrival_date <= date(?1, '+7 days')) AS a_venir,
        (SELECT COUNT(*) FROM reservation_rooms rr
          WHERE rr.deleted_at IS NULL
            AND rr.status IN ('PENDING', 'CONFIRMED')
            AND rr.room_id IS NULL
            AND rr.arrival_date <= date(?1, '+1 day')) AS sans_chambre,
        (SELECT COUNT(*) FROM reservations r
          WHERE r.deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM reservation_rooms w
                            WHERE w.reservation_id = r.id
                              AND w.is_walk_in = 1)
            AND julianday(r.created_at) >= julianday(?2)) AS prises,
        (SELECT COUNT(*) FROM reservation_rooms rr
          WHERE rr.deleted_at IS NULL AND rr.status = 'CHECKED_IN')
          AS en_sejour,
        (SELECT COUNT(*) FROM reservation_rooms rr
          WHERE rr.deleted_at IS NULL AND rr.is_walk_in = 1
            AND rr.arrival_date = ?1) AS directes
      ''',
      variables: [
        Variable.withString(jour),
        Variable.withString(debut.toUtc().toIso8601String()),
      ],
      readsFrom: {reservations, reservationRooms},
    ).watchSingle().map(
      (l) => ResumeMouvements(
        aVenir: l.read<int>('a_venir'),
        sansChambre: l.read<int>('sans_chambre'),
        prisesAujourdhui: l.read<int>('prises'),
        enSejour: l.read<int>('en_sejour'),
        directesAujourdhui: l.read<int>('directes'),
      ),
    );
  }

  /// Les deux tuiles de l'entretien : le menage et la maintenance.
  Stream<ResumeEntretien> watchResumeEntretien(String jour) {
    return customSelect(
      '''
      SELECT
        (SELECT COUNT(*) FROM rooms WHERE deleted_at IS NULL AND is_active = 1
            AND housekeeping_status = 'DIRTY') AS sales,
        (SELECT COUNT(*) FROM rooms WHERE deleted_at IS NULL AND is_active = 1
            AND housekeeping_status = 'IN_PROGRESS') AS en_cours,
        (SELECT COUNT(*) FROM rooms WHERE deleted_at IS NULL AND is_active = 1
            AND housekeeping_status IN ('CLEAN', 'INSPECTED')) AS propres,
        (SELECT COUNT(*) FROM rooms WHERE deleted_at IS NULL AND is_active = 1)
            AS chambres,
        (SELECT COUNT(*) FROM housekeeping_tasks WHERE deleted_at IS NULL
            AND business_date = ?1 AND status <> 'CANCELLED') AS taches,
        (SELECT COUNT(*) FROM housekeeping_tasks WHERE deleted_at IS NULL
            AND business_date = ?1 AND status IN ('DONE', 'INSPECTED'))
            AS taches_faites,
        (SELECT COUNT(*) FROM housekeeping_tasks WHERE deleted_at IS NULL
            AND status IN ('PENDING', 'ASSIGNED', 'IN_PROGRESS')
            AND assigned_to IS NULL) AS non_assignees,
        (SELECT COUNT(*) FROM maintenance_tickets WHERE deleted_at IS NULL
            AND status IN ('OPEN', 'ASSIGNED', 'IN_PROGRESS')) AS ouverts,
        (SELECT COUNT(*) FROM maintenance_tickets WHERE deleted_at IS NULL
            AND status IN ('OPEN', 'ASSIGNED', 'IN_PROGRESS')
            AND priority IN ('HIGH', 'URGENT')) AS urgents,
        (SELECT COUNT(*) FROM maintenance_tickets WHERE deleted_at IS NULL
            AND status = 'IN_PROGRESS') AS en_intervention,
        (SELECT COUNT(*) FROM rooms WHERE deleted_at IS NULL AND is_active = 1
            AND is_out_of_order = 1) AS hors_service,
        (SELECT COUNT(*) FROM maintenance_tickets WHERE deleted_at IS NULL
            AND status IN ('RESOLVED', 'CLOSED')
            AND julianday(resolved_at) >= julianday(?1, '-6 days'))
            AS resolus
      ''',
      variables: [Variable.withString(jour)],
      readsFrom: {rooms, housekeepingTasks, maintenanceTickets},
    ).watchSingle().map(
      (l) => ResumeEntretien(
        sales: l.read<int>('sales'),
        enCours: l.read<int>('en_cours'),
        propres: l.read<int>('propres'),
        chambres: l.read<int>('chambres'),
        taches: l.read<int>('taches'),
        tachesFaites: l.read<int>('taches_faites'),
        nonAssignees: l.read<int>('non_assignees'),
        ticketsOuverts: l.read<int>('ouverts'),
        urgents: l.read<int>('urgents'),
        enIntervention: l.read<int>('en_intervention'),
        horsService: l.read<int>('hors_service'),
        resolus7Jours: l.read<int>('resolus'),
      ),
    );
  }
}

class ResumeMouvements {
  const ResumeMouvements({
    required this.aVenir,
    required this.sansChambre,
    required this.prisesAujourdhui,
    required this.enSejour,
    required this.directesAujourdhui,
  });

  /// Arrivees prevues dans les sept prochains jours, aujourd'hui exclu.
  final int aVenir;

  /// Arrivees d'aujourd'hui ou de demain sans chambre attribuee.
  final int sansChambre;
  final int prisesAujourdhui;
  final int enSejour;
  final int directesAujourdhui;
}

class ResumeEntretien {
  const ResumeEntretien({
    required this.sales,
    required this.enCours,
    required this.propres,
    required this.chambres,
    required this.taches,
    required this.tachesFaites,
    required this.nonAssignees,
    required this.ticketsOuverts,
    required this.urgents,
    required this.enIntervention,
    required this.horsService,
    required this.resolus7Jours,
  });

  final int sales;
  final int enCours;
  final int propres;
  final int chambres;
  final int taches;
  final int tachesFaites;
  final int nonAssignees;
  final int ticketsOuverts;
  final int urgents;
  final int enIntervention;
  final int horsService;
  final int resolus7Jours;
}
