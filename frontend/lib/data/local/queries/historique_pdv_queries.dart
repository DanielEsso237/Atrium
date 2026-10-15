/// Les dernieres ventes d'un point de vente, sous ses tuiles (demande du 15
/// octobre) : ce qui vient d'etre servi, a qui, et ou en est l'argent.
///
/// Une vente, c'est une ardoise servie a ce comptoir dans la journee : les
/// lignes venues de ce point de vente, regroupees par ardoise -- trois bieres
/// portees en 101 dans la soiree font une vente, comme sur l'ecran Ventes.
library;

import 'package:drift/drift.dart';

import '../../../core/formats.dart';
import '../database.dart';

/// Ou en est l'argent d'une vente.
enum EtatVentePdv {
  /// Encaissee au comptoir.
  payee,

  /// Servie sur une ardoise du comptoir encore ouverte.
  aPayer,

  /// Portee sur l'ardoise d'une chambre : le client paiera a son depart.
  enChambre,
}

class VentePdv {
  const VentePdv({
    required this.ardoiseId,
    required this.titre,
    required this.articles,
    required this.quantite,
    required this.montant,
    required this.etat,
    this.derniereLe,
  });

  final String ardoiseId;

  /// La chambre et le client, le nom de l'ardoise, ou « Client divers n°3 ».
  final String titre;

  /// « 2 × Bière, Jus » : ce qui a ete servi, dans l'ordre.
  final String articles;
  final int quantite;
  final int montant;
  final EtatVentePdv etat;

  /// Le dernier article servi : c'est lui qui range la vente.
  final DateTime? derniereLe;
}

extension HistoriquePdvQueries on AtriumDatabase {
  /// Les ventes du jour a ce point de vente, les plus recentes d'abord.
  Stream<List<VentePdv>> watchDernieresVentesPdv({
    required String pointDeVente,
    required DateTime jour,
    int limite = 8,
  }) {
    return customSelect(
      '''
      SELECT f.id, f.type, f.status, f.tab_number, f.tab_label,
             g.first_name, g.last_name,
             (SELECT rm.number FROM reservation_rooms rr
                JOIN rooms rm ON rm.id = rr.room_id
               WHERE rr.id = f.reservation_room_id) AS chambre,
             SUM(fi.amount)   AS montant,
             SUM(fi.quantity) AS quantite,
             MAX(COALESCE(fi.posted_at, fi.created_at)) AS derniere,
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
         AND fi.source_id = ?1
         AND fi.business_date = ?2
       GROUP BY f.id
       ORDER BY derniere DESC
       LIMIT $limite
      ''',
      variables: [
        Variable.withString(pointDeVente),
        Variable.withString(formatIsoDate(jour)),
      ],
      readsFrom: {folioItems, folios, guests, reservationRooms, rooms},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          () {
            final prenom = r.readNullable<String>('first_name')?.trim() ?? '';
            final nom = r.readNullable<String>('last_name')?.trim() ?? '';
            final client = '$prenom $nom'.trim();
            final chambre = r.readNullable<String>('chambre');
            final numero = r.readNullable<int>('tab_number');
            final etiquette = r.readNullable<String>('tab_label');
            final enChambre = r.read<String>('type') != 'WALK_IN';
            final titre = chambre != null
                ? (client.isEmpty ? chambre : '$chambre · $client')
                : client.isNotEmpty
                ? client
                : etiquette ??
                      (numero == null
                          ? 'Client divers'
                          : 'Client divers n°$numero');
            return VentePdv(
              ardoiseId: r.read<String>('id'),
              titre: titre,
              articles: r.readNullable<String>('articles') ?? '',
              quantite: r.read<int>('quantite'),
              montant: r.read<int>('montant'),
              derniereLe: r.readNullable<DateTime>('derniere'),
              etat: enChambre
                  ? EtatVentePdv.enChambre
                  : r.read<String>('status') == 'OPEN'
                  ? EtatVentePdv.aPayer
                  : EtatVentePdv.payee,
            );
          }(),
      ],
    );
  }
}
