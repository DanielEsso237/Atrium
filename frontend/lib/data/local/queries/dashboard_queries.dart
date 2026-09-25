/// Les six tuiles du tableau de bord (cahier des charges, paragraphe 5.1).
library;

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
}
