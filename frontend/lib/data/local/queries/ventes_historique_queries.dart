/// L'historique des ventes des points de vente et des services (demande du
/// 18 octobre), et la recette jour par jour de leur tableau de bord.
///
/// Une vente, comme sur l'ecran Ventes et sous les tuiles du comptoir : une
/// ardoise servie a un point de vente dans une journee -- trois bieres
/// portees en 101 dans la soiree font une vente. Les tiroirs racontent
/// l'argent : ouverts avec leur fond, verses le soir, recus par la
/// reception.
///
/// Un seul calcul pour tous les points de vente : il prend la liste de ceux
/// que l'agent couvre, et ne connait aucun d'eux par son nom.
library;

import 'package:drift/drift.dart';

import '../../../core/formats.dart';
import '../database.dart';
import 'historique_pdv_queries.dart' show EtatVentePdv;

/// Une vente : une ardoise servie a un point de vente dans une journee.
class VenteHistorique {
  const VenteHistorique({
    required this.ardoiseId,
    required this.pointDeVente,
    required this.jour,
    required this.titre,
    required this.articles,
    required this.quantite,
    required this.montant,
    required this.etat,
    this.moment,
    this.agent,
  });

  final String ardoiseId;
  final String pointDeVente;

  /// La journee hoteliere de la vente.
  final DateTime jour;

  /// La chambre et le client, le nom de l'ardoise, ou « Client divers n°3 ».
  final String titre;

  /// « 2 × Bière, Jus » : ce qui a ete servi, dans l'ordre.
  final String articles;
  final int quantite;
  final int montant;
  final EtatVentePdv etat;

  /// Le dernier article servi : c'est lui qui range la vente.
  final DateTime? moment;

  /// Qui a servi le dernier article.
  final String? agent;
}

/// Un tiroir d'un point de vente, de son ouverture a sa reception.
class TiroirHistorique {
  const TiroirHistorique({
    required this.id,
    required this.pointDeVente,
    required this.fond,
    required this.attendu,
    this.agent,
    this.ouvertLe,
    this.fermeLe,
    this.declare,
    this.recuLe,
    this.recu,
    this.recuPar,
  });

  final String id;
  final String pointDeVente;
  final String? agent;
  final DateTime? ouvertLe;
  final int fond;

  /// Ferme : verse a la reception (la fermeture d'un tiroir de point de
  /// vente *est* son versement).
  final DateTime? fermeLe;

  /// Ce que l'agent dit remettre.
  final int? declare;
  final int attendu;
  final DateTime? recuLe;

  /// Ce que la reception dit avoir recu.
  final int? recu;
  final String? recuPar;
}

extension VentesHistoriqueQueries on AtriumDatabase {
  /// La recette de chaque journee de [du] a [au] compris, dans l'ordre : une
  /// journee sans vente vaut zero, elle reste sur le trace.
  Stream<List<int>> watchRecetteParJour({
    required List<String> pointsDeVente,
    required DateTime du,
    required DateTime au,
  }) {
    final debut = DateTime(du.year, du.month, du.day);
    final fin = DateTime(au.year, au.month, au.day);
    final jours = <String>[
      for (
        var j = debut;
        !j.isAfter(fin);
        j = DateTime(j.year, j.month, j.day + 1)
      )
        formatIsoDate(j),
    ];
    if (pointsDeVente.isEmpty || jours.isEmpty) {
      return Stream.value(List.filled(jours.length, 0));
    }
    final dans = [
      for (var i = 0; i < pointsDeVente.length; i++) '?${i + 3}',
    ].join(', ');
    return customSelect(
      '''
      SELECT fi.business_date AS jour, COALESCE(SUM(fi.amount), 0) AS recette
        FROM folio_items fi
       WHERE fi.deleted_at IS NULL
         AND fi.is_void = 0
         AND fi.source_table = 'outlets'
         AND fi.source_id IN ($dans)
         AND fi.business_date BETWEEN ?1 AND ?2
       GROUP BY fi.business_date
      ''',
      variables: [
        Variable.withString(jours.first),
        Variable.withString(jours.last),
        for (final id in pointsDeVente) Variable.withString(id),
      ],
      readsFrom: {folioItems},
    ).watch().map((rangs) {
      final parJour = {
        for (final r in rangs) r.read<String>('jour'): r.read<int>('recette'),
      };
      return [for (final j in jours) parJour[j] ?? 0];
    });
  }

  /// Les ventes de ces points de vente depuis la journee [depuis] (toutes
  /// sans elle), les plus recentes d'abord.
  ///
  /// Une seule requete, agents compris : une seconde lecture enchainee au
  /// flux resterait en suspens a la fermeture de la base.
  Stream<List<VenteHistorique>> watchHistoriqueVentes({
    required List<String> pointsDeVente,
    DateTime? depuis,
    int limite = 1500,
  }) {
    if (pointsDeVente.isEmpty) return Stream.value(const []);
    final dans = [
      for (var i = 0; i < pointsDeVente.length; i++) '?${i + 2}',
    ].join(', ');
    return customSelect(
      '''
      SELECT v.*, u.first_name AS agent_prenom, u.last_name AS agent_nom
        FROM (
          SELECT f.id, f.type, f.status, f.tab_number, f.tab_label,
                 fi.source_id     AS point_de_vente,
                 fi.business_date AS jour,
                 g.first_name, g.last_name,
                 (SELECT rm.number FROM reservation_rooms rr
                    JOIN rooms rm ON rm.id = rr.room_id
                   WHERE rr.id = f.reservation_room_id) AS chambre,
                 SUM(fi.amount)   AS montant,
                 SUM(fi.quantity) AS quantite,
                 MAX(COALESCE(fi.posted_at, fi.created_at)) AS derniere,
                 MAX(fi.posted_by) AS agent_id,
                 GROUP_CONCAT(
                   CASE WHEN fi.quantity > 1
                        THEN fi.quantity || ' × ' || fi.label
                        ELSE fi.label END, ', ') AS articles
            FROM folio_items fi
            JOIN folios f      ON f.id = fi.folio_id
            LEFT JOIN guests g ON g.id = f.guest_id
           WHERE fi.deleted_at IS NULL
             AND fi.is_void = 0
             AND fi.source_table = 'outlets'
             AND fi.source_id IN ($dans)
             AND (?1 IS NULL OR fi.business_date >= ?1)
           GROUP BY f.id, fi.business_date, fi.source_id
        ) v
        LEFT JOIN users u ON u.id = v.agent_id
       ORDER BY v.derniere DESC
       LIMIT $limite
      ''',
      variables: [
        Variable<String>(depuis == null ? null : formatIsoDate(depuis)),
        for (final id in pointsDeVente) Variable.withString(id),
      ],
      readsFrom: {folioItems, folios, guests, reservationRooms, rooms, users},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          VenteHistorique(
            ardoiseId: r.read<String>('id'),
            pointDeVente: r.read<String>('point_de_vente'),
            jour: DateTime.parse(r.read<String>('jour')),
            titre: _titre(r),
            articles: r.readNullable<String>('articles') ?? '',
            quantite: r.read<int>('quantite'),
            montant: r.read<int>('montant'),
            moment: r.readNullable<DateTime>('derniere'),
            agent: _nom(r, 'agent_prenom', 'agent_nom'),
            etat: r.read<String>('type') != 'WALK_IN'
                ? EtatVentePdv.enChambre
                : r.read<String>('status') == 'OPEN'
                ? EtatVentePdv.aPayer
                : EtatVentePdv.payee,
          ),
      ],
    );
  }

  /// Les tiroirs de ces points de vente ouverts depuis [depuis] (tous sans
  /// lui), ou encore ouverts, les plus recents d'abord.
  Stream<List<TiroirHistorique>> watchHistoriqueTiroirs({
    required List<String> pointsDeVente,
    DateTime? depuis,
  }) {
    if (pointsDeVente.isEmpty) return Stream.value(const []);
    final dans = [
      for (var i = 0; i < pointsDeVente.length; i++) '?${i + 2}',
    ].join(', ');
    return customSelect(
      '''
      SELECT c.id, c.outlet_id, c.opened_at, c.opening_float, c.closed_at,
             c.counted_amount, c.expected_amount, c.received_at,
             c.received_amount,
             a.first_name AS agent_prenom, a.last_name AS agent_nom,
             r.first_name AS recu_prenom, r.last_name AS recu_nom
        FROM cash_sessions c
        LEFT JOIN users a ON a.id = c.user_id
        LEFT JOIN users r ON r.id = c.received_by
       WHERE c.deleted_at IS NULL
         AND c.outlet_id IN ($dans)
         AND (?1 IS NULL OR c.opened_at >= ?1 OR c.status = 'OPEN')
       ORDER BY c.opened_at DESC
      ''',
      variables: [
        Variable<DateTime>(depuis?.toUtc()),
        for (final id in pointsDeVente) Variable.withString(id),
      ],
      readsFrom: {cashSessions, users},
    ).watch().map(
      (rangs) => [
        for (final c in rangs)
          TiroirHistorique(
            id: c.read<String>('id'),
            pointDeVente: c.read<String>('outlet_id'),
            agent: _nom(c, 'agent_prenom', 'agent_nom'),
            ouvertLe: c.readNullable<DateTime>('opened_at'),
            fond: c.read<int>('opening_float'),
            fermeLe: c.readNullable<DateTime>('closed_at'),
            declare: c.readNullable<DateTime>('closed_at') == null
                ? null
                : c.readNullable<int>('counted_amount'),
            attendu: c.read<int>('expected_amount'),
            recuLe: c.readNullable<DateTime>('received_at'),
            recu: c.readNullable<int>('received_amount'),
            recuPar: _nom(c, 'recu_prenom', 'recu_nom'),
          ),
      ],
    );
  }

  /// « Paul Essomba », ou `null` sans agent connu.
  static String? _nom(QueryRow r, String prenom, String nom) {
    final n =
        '${r.readNullable<String>(prenom) ?? ''} '
                '${r.readNullable<String>(nom) ?? ''}'
            .trim();
    return n.isEmpty ? null : n;
  }

  /// Comme sous les tuiles du comptoir : la chambre et le client, le nom
  /// donne a l'ardoise, ou son numero de passage.
  static String _titre(QueryRow r) {
    final prenom = r.readNullable<String>('first_name')?.trim() ?? '';
    final nom = r.readNullable<String>('last_name')?.trim() ?? '';
    final client = '$prenom $nom'.trim();
    final chambre = r.readNullable<String>('chambre');
    final numero = r.readNullable<int>('tab_number');
    final etiquette = r.readNullable<String>('tab_label');
    if (chambre != null) {
      return client.isEmpty ? 'Chambre $chambre' : 'Chambre $chambre, $client';
    }
    if (client.isNotEmpty) return client;
    return etiquette ??
        (numero == null ? 'Client divers' : 'Client divers n°$numero');
  }
}
