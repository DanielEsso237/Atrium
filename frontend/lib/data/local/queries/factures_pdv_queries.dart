/// Les factures des points de vente (demande du 14 octobre, ticket D2).
///
/// Une facture du comptoir, c'est un encaissement tombe dans le tiroir d'un
/// point de vente : une vente payee tout de suite, ou une ardoise payee a la
/// fin. Elle porte ce qui a ete servi a ce comptoir sur l'ardoise payee, de
/// quoi refaire le ticket. Les encaissements des collegues descendent aussi
/// (`GET /outlet-activity`) : chacun retrouve les tickets de son comptoir,
/// pas seulement ceux de sa tablette.
library;

import 'package:drift/drift.dart';

import '../../../core/formats.dart';
import '../database.dart';
import '../enums.dart';

/// Une facture du comptoir, telle que l'ecran la montre et que le ticket la
/// refait.
class FacturePdv {
  const FacturePdv({
    required this.paiementId,
    required this.ardoiseId,
    required this.numero,
    required this.pointDeVenteId,
    required this.pointDeVente,
    required this.moyen,
    required this.montant,
    required this.lignes,
    this.recueLe,
    this.client,
    this.agent,
  });

  final String paiementId;
  final String ardoiseId;

  /// Le numero de l'ardoise (« FOL-… ») : celui du ticket.
  final String numero;
  final String pointDeVenteId;
  final String pointDeVente;
  final PaymentMethod moyen;
  final int montant;

  /// `(libelle, prix unitaire, quantite)` : ce qui a ete servi a ce comptoir.
  final List<(String, int, int)> lignes;
  final DateTime? recueLe;

  /// Le client loge, ou le nom donne a l'ardoise (« Table 4 »).
  final String? client;

  /// L'agent qui a encaisse.
  final String? agent;
}

extension FacturesPdvQueries on AtriumDatabase {
  /// Les factures d'une journee hoteliere dans ces points de vente, les plus
  /// recentes d'abord. Les remboursements n'en sont pas.
  Stream<List<FacturePdv>> watchFacturesPdv({
    required List<String> pointsDeVente,
    required DateTime jour,
  }) {
    if (pointsDeVente.isEmpty) return Stream.value(const []);
    final dans = [
      for (var i = 0; i < pointsDeVente.length; i++) '?${i + 2}',
    ].join(', ');
    return customSelect(
      '''
      SELECT p.id AS paiement, p.folio_id AS ardoise, p.method AS moyen,
             p.amount AS montant, p.received_at AS recue_le,
             f.number AS numero, f.tab_label AS nom_ardoise,
             o.id AS pdv, o.label AS pdv_libelle,
             g.first_name AS client_prenom, g.last_name AS client_nom,
             u.first_name AS agent_prenom, u.last_name AS agent_nom
        FROM payments p
        JOIN cash_sessions cs ON cs.id = p.cash_session_id
        JOIN outlets o        ON o.id = cs.outlet_id
        JOIN folios f         ON f.id = p.folio_id
        LEFT JOIN guests g    ON g.id = f.guest_id
        LEFT JOIN users u     ON u.id = p.received_by
       WHERE p.deleted_at IS NULL
         AND p.is_refund = 0
         AND p.business_date = ?1
         AND cs.outlet_id IN ($dans)
       ORDER BY p.received_at DESC
      ''',
      variables: [
        Variable.withString(formatIsoDate(jour)),
        for (final id in pointsDeVente) Variable.withString(id),
      ],
      readsFrom: {payments, cashSessions, outlets, folios, guests, users},
    ).watch().asyncMap((rangs) async {
      final factures = <FacturePdv>[];
      for (final r in rangs) {
        final pdv = r.read<String>('pdv');
        final ardoise = r.read<String>('ardoise');
        final lignes = await customSelect(
          '''
          SELECT label, unit_price, quantity FROM folio_items
           WHERE folio_id = ?1 AND deleted_at IS NULL AND is_void = 0
             AND source_table = 'outlets' AND source_id = ?2
           ORDER BY posted_at, created_at
          ''',
          variables: [Variable.withString(ardoise), Variable.withString(pdv)],
          readsFrom: {folioItems},
        ).get();
        String? nom(String prenom, String famille) {
          final p = r.readNullable<String>(prenom)?.trim() ?? '';
          final f = r.readNullable<String>(famille)?.trim() ?? '';
          final tout = '$p $f'.trim();
          return tout.isEmpty ? null : tout;
        }

        factures.add(
          FacturePdv(
            paiementId: r.read<String>('paiement'),
            ardoiseId: ardoise,
            numero: r.read<String>('numero'),
            pointDeVenteId: pdv,
            pointDeVente: r.read<String>('pdv_libelle'),
            moyen: PaymentMethod.values.byName(r.read<String>('moyen')),
            montant: r.read<int>('montant'),
            recueLe: r.readNullable<DateTime>('recue_le'),
            client:
                nom('client_prenom', 'client_nom') ??
                r.readNullable<String>('nom_ardoise'),
            agent: nom('agent_prenom', 'agent_nom'),
            lignes: [
              for (final l in lignes)
                (
                  l.read<String>('label'),
                  l.read<int>('unit_price'),
                  l.read<int>('quantity'),
                ),
            ],
          ),
        );
      }
      return factures;
    });
  }
}
