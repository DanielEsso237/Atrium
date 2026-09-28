/// Les chiffres du tableau de bord (cahier des charges, paragraphe 5.1).
///
/// Les six tuiles, puis ce qui les met en perspective : l'historique des
/// derniers jours, la repartition des chambres par type, l'activite de la
/// journee heure par heure et les derniers evenements. Tout vient de la base
/// locale, en flux continu : le tableau de bord bouge quand la reception
/// travaille, sans que personne ne rafraichisse.
library;

import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../../core/business_day.dart';
import '../../../core/formats.dart';
import '../database.dart';

/// Ce que montre le haut de l'ecran d'accueil.
class DashboardSummary {
  const DashboardSummary({
    required this.chambresTotal,
    required this.chambresOccupees,
    required this.reservationsActives,
    required this.arriveesDuJour,
    required this.arriveesRestantes,
    required this.departsDuJour,
    required this.departsRestants,
    required this.caDuJour,
    required this.chambresANettoyer,
  });

  final int chambresTotal;
  final int chambresOccupees;
  final int reservationsActives;

  /// Toutes les arrivees de la journee, faites ou non.
  ///
  /// Le total et non le reste : un compteur qui retombe a zero a mesure qu'on
  /// travaille se lit comme une panne, et prive la reception de la seule
  /// chose qu'elle veut savoir en un coup d'oeil -- l'ampleur de sa journee.
  /// Ce qui reste a faire se lit sur `arriveesRestantes`.
  final int arriveesDuJour;
  final int arriveesRestantes;

  final int departsDuJour;
  final int departsRestants;

  /// Chiffre d'affaires de la journee hoteliere, en francs CFA entiers.
  final int caDuJour;
  final int chambresANettoyer;

  /// Taux d'occupation en pourcentage entier, ou `null` si l'hotel n'a pas
  /// encore de chambres — un taux sur zero chambre n'a pas de sens.
  int? get tauxOccupation => chambresTotal == 0
      ? null
      : (chambresOccupees * 100 / chambresTotal).round();
}

extension DashboardQueries on AtriumDatabase {
  /// Les six chiffres, en une seule requete et en flux continu.
  ///
  /// Une requete plutot que six : l'ecran se repeint d'un coup, et surtout les
  /// chiffres sont pris au meme instant. Six lectures separees pourraient
  /// montrer 42 chambres occupees et 3 arrivees deja prises en charge sur une
  /// photo ou les deux ne collent pas.
  ///
  /// `watch()` et non `get()` : quand la reception fait un check-in, la tuile
  /// bouge sans que personne ne rafraichisse. C'est ce qui donnera le temps
  /// reel du paragraphe 3.2 une fois la synchronisation branchee.
  Stream<DashboardSummary> watchDashboard({DateTime? jour}) {
    // La journee hoteliere, pas la date du calendrier : a minuit une minute,
    // le service de nuit travaille encore sur la journee de la veille.
    final journee = jour == null
        ? businessDateNow()
        : formatIsoDate(businessDayFor(jour));

    return customSelect(
      '''
      SELECT
        (SELECT COUNT(*) FROM rooms
          WHERE deleted_at IS NULL AND is_active = 1)            AS total,

        (SELECT COUNT(*) FROM rooms
          WHERE deleted_at IS NULL AND is_active = 1
            AND occupancy_status = 'OCCUPIED')                   AS occupees,

        (SELECT COUNT(*) FROM rooms
          WHERE deleted_at IS NULL AND is_active = 1
            AND housekeeping_status = 'DIRTY')                   AS a_nettoyer,

        (SELECT COUNT(*) FROM reservations
          WHERE deleted_at IS NULL
            AND status IN ('PENDING','CONFIRMED','CHECKED_IN'))  AS reservations,

        (SELECT COUNT(*) FROM reservation_rooms
          WHERE deleted_at IS NULL
            AND arrival_date = ?1
            AND status <> 'CANCELLED')                           AS arrivees,

        (SELECT COUNT(*) FROM reservation_rooms
          WHERE deleted_at IS NULL
            AND arrival_date = ?1
            AND status IN ('PENDING','CONFIRMED'))               AS arrivees_restantes,

        (SELECT COUNT(*) FROM reservation_rooms
          WHERE deleted_at IS NULL
            AND departure_date = ?1
            AND status IN ('CHECKED_IN','CHECKED_OUT'))          AS departs,

        (SELECT COUNT(*) FROM reservation_rooms
          WHERE deleted_at IS NULL
            AND departure_date = ?1
            AND status = 'CHECKED_IN')                           AS departs_restants,

        (SELECT COALESCE(SUM(amount), 0) FROM folio_items
          WHERE deleted_at IS NULL
            AND business_date = ?1)                              AS ca
      ''',
      variables: [Variable.withString(journee)],
      readsFrom: {rooms, reservations, reservationRooms, folioItems},
    ).watchSingle().map(
      (row) => DashboardSummary(
        chambresTotal: row.read<int>('total'),
        chambresOccupees: row.read<int>('occupees'),
        reservationsActives: row.read<int>('reservations'),
        arriveesDuJour: row.read<int>('arrivees'),
        arriveesRestantes: row.read<int>('arrivees_restantes'),
        departsDuJour: row.read<int>('departs'),
        departsRestants: row.read<int>('departs_restants'),
        caDuJour: row.read<int>('ca'),
        chambresANettoyer: row.read<int>('a_nettoyer'),
      ),
    );
  }

  /// Les derniers jours, du plus ancien a la journee en cours.
  ///
  /// Une ligne par journee hoteliere, meme vide : une courbe a laquelle il
  /// manque les jours sans activite ment sur la pente. Les jours sont generes
  /// ici puis passes a la requete, pour que la tablette et le serveur parlent
  /// des memes dates (voir `business_day.dart`).
  Stream<List<JourneeStats>> watchHistorique({
    required int jours,
    DateTime? jour,
  }) {
    final fin = businessDayFor(jour ?? DateTime.now());
    // Arithmetique sur les composantes et non sur des durees : un changement
    // d'heure ferait sauter ou doubler un jour.
    final dates = [
      for (var i = jours - 1; i >= 0; i--)
        DateTime(fin.year, fin.month, fin.day - i),
    ];
    final valeurs = List.filled(dates.length, '(?)').join(', ');

    return customSelect(
      '''
      WITH jours(d) AS (VALUES $valeurs)
      SELECT
        j.d AS jour,

        -- Une chambre est occupee la nuit du d si le client est arrive au
        -- plus tard le d et repart apres.
        (SELECT COUNT(*) FROM reservation_rooms rr
          WHERE rr.deleted_at IS NULL
            AND rr.status IN ('CHECKED_IN','CHECKED_OUT')
            AND rr.arrival_date <= j.d
            AND rr.departure_date > j.d)                        AS occupees,

        (SELECT COUNT(*) FROM reservations r
          WHERE r.deleted_at IS NULL
            AND r.status IN ('PENDING','CONFIRMED','CHECKED_IN','CHECKED_OUT')
            AND r.arrival_date <= j.d
            AND r.departure_date > j.d)                         AS reservations,

        (SELECT COUNT(*) FROM reservation_rooms rr
          WHERE rr.deleted_at IS NULL
            AND rr.arrival_date = j.d
            AND rr.status <> 'CANCELLED')                       AS arrivees,

        (SELECT COUNT(*) FROM reservation_rooms rr
          WHERE rr.deleted_at IS NULL
            AND rr.departure_date = j.d
            AND rr.status IN ('CHECKED_IN','CHECKED_OUT'))      AS departs
      FROM jours j
      ORDER BY j.d
      ''',
      variables: [for (final d in dates) Variable.withString(formatIsoDate(d))],
      readsFrom: {reservations, reservationRooms},
    ).watch().map(
      (lignes) => [
        for (final l in lignes)
          JourneeStats(
            jour: parseIsoDate(l.read<String>('jour'))!,
            occupees: l.read<int>('occupees'),
            reservations: l.read<int>('reservations'),
            arrivees: l.read<int>('arrivees'),
            departs: l.read<int>('departs'),
          ),
      ],
    );
  }

  /// Les chambres par type, et combien de chacune sont occupees.
  ///
  /// Les types sans chambre sont omis : un segment de zero degre et une ligne
  /// « 0 / 0 » dans la legende n'apprennent rien a la reception.
  Stream<List<RepartitionType>> watchRepartition() {
    return customSelect(
      '''
      SELECT
        rt.label AS libelle,
        COUNT(r.id) AS total,
        COALESCE(SUM(CASE WHEN r.occupancy_status = 'OCCUPIED'
                          THEN 1 ELSE 0 END), 0) AS occupees
      FROM room_types rt
      LEFT JOIN rooms r
        ON r.room_type_id = rt.id
       AND r.deleted_at IS NULL
       AND r.is_active = 1
      WHERE rt.deleted_at IS NULL AND rt.is_active = 1
      GROUP BY rt.id
      HAVING COUNT(r.id) > 0
      ORDER BY rt.sort_order, rt.label
      ''',
      readsFrom: {roomTypes, rooms},
    ).watch().map(
      (lignes) => [
        for (final l in lignes)
          RepartitionType(
            libelle: l.read<String>('libelle'),
            total: l.read<int>('total'),
            occupees: l.read<int>('occupees'),
          ),
      ],
    );
  }

  /// Les arrivees et les departs enregistres dans la journee, par tranche de
  /// trois heures.
  ///
  /// Le regroupement se fait ici et non en SQL : les instants sont stockes en
  /// UTC, et c'est l'heure **locale** de l'hotel qui dit a quelle tranche un
  /// check-in appartient. SQLite ne connait pas le fuseau de la tablette.
  Stream<ActiviteHoraire> watchActiviteDuJour({DateTime? jour}) {
    final journee = businessDayFor(jour ?? DateTime.now());
    // Large expres : un depart anticipe ou tardif n'a pas lieu a la date
    // prevue. Le tri fin se fait sur l'instant, ci-dessous.
    final borne = formatIsoDate(
      DateTime(journee.year, journee.month, journee.day - 2),
    );

    return customSelect(
      '''
      SELECT checked_in_at, checked_out_at
      FROM reservation_rooms
      WHERE deleted_at IS NULL
        AND (checked_in_at IS NOT NULL OR checked_out_at IS NOT NULL)
        AND (arrival_date >= ?1 OR departure_date >= ?1)
      ''',
      variables: [Variable.withString(borne)],
      readsFrom: {reservationRooms},
    ).watch().map((lignes) {
      final arrivees = List.filled(ActiviteHoraire.tranches.length, 0);
      final departs = List.filled(ActiviteHoraire.tranches.length, 0);

      void compter(DateTime? instant, List<int> cible) {
        if (instant == null) return;
        final local = instant.toLocal();
        if (businessDayFor(local) != journee) return;
        cible[trancheHoraire(local.hour)]++;
      }

      for (final l in lignes) {
        compter(l.readNullable<DateTime>('checked_in_at'), arrivees);
        compter(l.readNullable<DateTime>('checked_out_at'), departs);
      }
      return ActiviteHoraire(arrivees: arrivees, departs: departs);
    });
  }

  /// Les derniers evenements de l'hotel, du plus recent au plus ancien :
  /// reservations prises, arrivees, departs, commandes.
  ///
  /// Tri par `julianday()` et non sur le texte : un horodatage ecrit par le
  /// serveur peut porter un decalage horaire, et deux formats ne se trient pas
  /// alphabetiquement.
  Stream<List<Activite>> watchDernieresActivites({int limite = 20}) {
    return customSelect(
      '''
      SELECT * FROM (
        SELECT 'reservation' AS genre, r.created_at AS moment,
               NULL AS chambre,
               (SELECT rt.label FROM reservation_rooms rr
                  JOIN room_types rt ON rt.id = rr.room_type_id
                 WHERE rr.reservation_id = r.id AND rr.deleted_at IS NULL
                 LIMIT 1) AS type_chambre,
               g.first_name AS prenom, g.last_name AS nom,
               NULL AS point_de_vente
          FROM reservations r
          LEFT JOIN guests g ON g.id = r.guest_id
         WHERE r.deleted_at IS NULL

        UNION ALL
        SELECT 'arrivee', rr.checked_in_at, rm.number, rt.label,
               g.first_name, g.last_name, NULL
          FROM reservation_rooms rr
          JOIN reservations r ON r.id = rr.reservation_id
          LEFT JOIN rooms rm ON rm.id = rr.room_id
          LEFT JOIN room_types rt ON rt.id = rr.room_type_id
          LEFT JOIN guests g ON g.id = r.guest_id
         WHERE rr.deleted_at IS NULL AND rr.checked_in_at IS NOT NULL

        UNION ALL
        SELECT 'depart', rr.checked_out_at, rm.number, rt.label,
               g.first_name, g.last_name, NULL
          FROM reservation_rooms rr
          JOIN reservations r ON r.id = rr.reservation_id
          LEFT JOIN rooms rm ON rm.id = rr.room_id
          LEFT JOIN room_types rt ON rt.id = rr.room_type_id
          LEFT JOIN guests g ON g.id = r.guest_id
         WHERE rr.deleted_at IS NULL AND rr.checked_out_at IS NOT NULL

        UNION ALL
        SELECT 'commande', o.created_at, rm.number, NULL,
               g.first_name, g.last_name, ot.label
          FROM orders o
          LEFT JOIN outlets ot ON ot.id = o.outlet_id
          LEFT JOIN rooms rm ON rm.id = o.room_id
          LEFT JOIN guests g ON g.id = o.guest_id
         WHERE o.deleted_at IS NULL AND o.status <> 'CANCELLED'
      )
      ORDER BY julianday(moment) DESC
      LIMIT ?1
      ''',
      variables: [Variable.withInt(limite)],
      readsFrom: {
        reservations,
        reservationRooms,
        rooms,
        roomTypes,
        guests,
        orders,
        outlets,
      },
    ).watch().map(
      (lignes) => [
        for (final l in lignes)
          Activite(
            genre: GenreActivite.values.byName(l.read<String>('genre')),
            moment: l.read<DateTime>('moment'),
            chambre: l.readNullable<String>('chambre'),
            typeChambre: l.readNullable<String>('type_chambre'),
            client: _nomClient(
              l.readNullable<String>('prenom'),
              l.readNullable<String>('nom'),
            ),
            pointDeVente: l.readNullable<String>('point_de_vente'),
          ),
      ],
    );
  }

  /// Les notifications que personne n'a encore lues, pour la cloche.
  Stream<int> watchNotificationsNonLues() {
    return customSelect(
      '''
      SELECT COUNT(*) AS n FROM notifications
      WHERE deleted_at IS NULL AND read_at IS NULL AND is_read = 0
      ''',
      readsFrom: {notifications},
    ).watchSingle().map((l) => l.read<int>('n'));
  }

  /// Les dernieres notifications, lues ou non.
  Stream<List<NotificationResume>> watchNotifications({int limite = 20}) {
    return customSelect(
      '''
      SELECT title, body, created_at, read_at, is_read FROM notifications
      WHERE deleted_at IS NULL
      ORDER BY julianday(created_at) DESC
      LIMIT ?1
      ''',
      variables: [Variable.withInt(limite)],
      readsFrom: {notifications},
    ).watch().map(
      (lignes) => [
        for (final l in lignes)
          NotificationResume(
            titre: l.read<String>('title'),
            corps: l.readNullable<String>('body'),
            moment: l.read<DateTime>('created_at'),
            lue:
                l.read<bool>('is_read') ||
                l.readNullable<DateTime>('read_at') != null,
          ),
      ],
    );
  }
}

String? _nomClient(String? prenom, String? nom) {
  final complet = [
    prenom?.trim(),
    nom?.trim(),
  ].whereType<String>().where((p) => p.isNotEmpty).join(' ');
  return complet.isEmpty ? null : complet;
}

/// Une journee de l'historique.
class JourneeStats {
  const JourneeStats({
    required this.jour,
    required this.occupees,
    required this.reservations,
    required this.arrivees,
    required this.departs,
  });

  /// Date d'exploitation, sans heure.
  final DateTime jour;

  /// Chambres occupees la nuit de ce jour.
  final int occupees;

  /// Reservations dont le sejour couvre ce jour.
  final int reservations;
  final int arrivees;
  final int departs;
}

/// Un type de chambre dans l'anneau de repartition.
class RepartitionType {
  const RepartitionType({
    required this.libelle,
    required this.total,
    required this.occupees,
  });

  final String libelle;
  final int total;
  final int occupees;
}

/// Arrivees et departs de la journee, par tranche de trois heures.
class ActiviteHoraire {
  const ActiviteHoraire({required this.arrivees, required this.departs});

  /// L'heure de debut de chaque tranche. La journee hoteliere commence a 6 h ;
  /// la derniere tranche court de 21 h jusqu'a la bascule du lendemain, et
  /// garde donc aussi les arrivees tardives de la nuit.
  static const tranches = [6, 9, 12, 15, 18, 21];

  final List<int> arrivees;
  final List<int> departs;

  bool get estVide =>
      arrivees.every((n) => n == 0) && departs.every((n) => n == 0);
}

/// La tranche (0 a 5) d'une heure locale.
int trancheHoraire(int heure) {
  if (heure < ActiviteHoraire.tranches.first) {
    return ActiviteHoraire.tranches.length - 1;
  }
  return math.min((heure - 6) ~/ 3, ActiviteHoraire.tranches.length - 1);
}

enum GenreActivite { reservation, arrivee, depart, commande }

/// Un evenement du fil « Dernieres activites ».
class Activite {
  const Activite({
    required this.genre,
    required this.moment,
    this.chambre,
    this.typeChambre,
    this.client,
    this.pointDeVente,
  });

  final GenreActivite genre;
  final DateTime moment;

  /// Numero de la chambre, quand elle est connue.
  final String? chambre;

  /// Libelle du type de chambre, pour une reservation pas encore attribuee.
  final String? typeChambre;
  final String? client;

  /// Le point de vente d'une commande.
  final String? pointDeVente;
}

/// Une notification, pour la liste de la cloche.
class NotificationResume {
  const NotificationResume({
    required this.titre,
    required this.moment,
    required this.lue,
    this.corps,
  });

  final String titre;
  final String? corps;
  final DateTime moment;
  final bool lue;
}
