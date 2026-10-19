/// L'historique des finances (demande du 18 octobre) : tout l'argent qui
/// entre et sort de l'hotel, et les pieces qui l'accompagnent.
///
/// - **les encaissements** et leurs remboursements, avec le client, la
///   chambre ou le comptoir, le moyen, la reference et l'agent ;
/// - **les arrhes** recues sur les reservations ;
/// - **les depenses** hors stock, annulees comprises (elles restent) ;
/// - **les caisses** : ouvertes avec leur fond, fermees avec leur ecart,
///   versements des comptoirs recus par la reception ;
/// - **les factures** emises ou annulees.
///
/// Chaque lecture est une seule requete : une seconde lecture enchainee au
/// flux resterait en suspens a la fermeture de la base.
library;

import 'package:drift/drift.dart';

import '../../../core/formats.dart';
import '../database.dart';
import '../enums.dart';

/// Un encaissement, ou son remboursement.
class EncaissementHistorique {
  const EncaissementHistorique({
    required this.id,
    required this.montant,
    required this.moyen,
    required this.remboursement,
    this.annule,
    this.moment,
    this.client,
    this.chambre,
    this.pointDeVente,
    this.reference,
    this.agent,
  });

  final String id;
  final int montant;
  final PaymentMethod moyen;
  final bool remboursement;

  /// Pour un remboursement : l'encaissement qu'il annule.
  final String? annule;
  final DateTime? moment;
  final String? client;
  final String? chambre;

  /// Le comptoir dont le tiroir a recu l'argent ; nul a la reception.
  final String? pointDeVente;
  final String? reference;
  final String? agent;
}

/// Des arrhes recues sur une reservation.
class ArrhesHistorique {
  const ArrhesHistorique({
    required this.id,
    required this.reference,
    required this.montant,
    required this.moment,
    this.client,
  });

  final String id;
  final String reference;
  final int montant;
  final DateTime moment;
  final String? client;
}

/// Une depense hors stock.
class DepenseHistorique {
  const DepenseHistorique({
    required this.id,
    required this.libelle,
    required this.rubrique,
    required this.montant,
    required this.jour,
    required this.annulee,
    this.moment,
    this.moyen,
    this.fournisseur,
    this.motifAnnulation,
    this.agent,
  });

  final String id;
  final String libelle;
  final ExpenseCategory rubrique;
  final int montant;
  final DateTime jour;
  final bool annulee;

  /// Quand elle a ete saisie.
  final DateTime? moment;
  final PaymentMethod? moyen;
  final String? fournisseur;
  final String? motifAnnulation;
  final String? agent;
}

/// Une caisse : la centrale (sans point de vente) ou le tiroir d'un comptoir.
class CaisseHistorique {
  const CaisseHistorique({
    required this.id,
    required this.fond,
    required this.attendu,
    required this.ecart,
    this.pointDeVente,
    this.agent,
    this.ouverteLe,
    this.fermeeLe,
    this.compte,
    this.recuLe,
    this.recu,
    this.recuPar,
  });

  final String id;

  /// Nul : la caisse centrale, a la reception.
  final String? pointDeVente;
  final String? agent;
  final DateTime? ouverteLe;
  final int fond;
  final DateTime? fermeeLe;
  final int? compte;
  final int attendu;

  /// Compte moins attendu, a la fermeture.
  final int ecart;
  final DateTime? recuLe;
  final int? recu;
  final String? recuPar;
}

/// Une facture emise, et son annulation s'il y en a une.
class FactureHistorique {
  const FactureHistorique({
    required this.id,
    required this.numero,
    required this.total,
    required this.statut,
    this.emiseLe,
    this.annuleeLe,
    this.motifAnnulation,
    this.client,
  });

  final String id;
  final String numero;
  final int total;
  final InvoiceStatus statut;
  final DateTime? emiseLe;
  final DateTime? annuleeLe;
  final String? motifAnnulation;
  final String? client;
}

extension FinancesHistoriqueQueries on AtriumDatabase {
  /// Les encaissements et remboursements depuis [depuis] (tous sans lui),
  /// les plus recents d'abord.
  Stream<List<EncaissementHistorique>> watchEncaissementsHistorique({
    DateTime? depuis,
    int limite = 2000,
  }) {
    return customSelect(
      '''
      SELECT p.id, p.amount, p.method, p.is_refund, p.reverses_payment_id,
             p.reference,
             COALESCE(p.received_at, p.created_at) AS moment,
             f.type AS type_ardoise, f.tab_number, f.tab_label,
             g.first_name, g.last_name,
             (SELECT rm.number FROM reservation_rooms rr
                JOIN rooms rm ON rm.id = rr.room_id
               WHERE rr.id = f.reservation_room_id) AS chambre,
             o.label AS point_de_vente,
             u.first_name AS agent_prenom, u.last_name AS agent_nom
        FROM payments p
        LEFT JOIN folios f        ON f.id = p.folio_id
        LEFT JOIN guests g        ON g.id = f.guest_id
        LEFT JOIN cash_sessions c ON c.id = p.cash_session_id
        LEFT JOIN outlets o       ON o.id = c.outlet_id
        LEFT JOIN users u         ON u.id = p.received_by
       WHERE p.deleted_at IS NULL
         AND (?1 IS NULL OR COALESCE(p.received_at, p.created_at) >= ?1)
       ORDER BY moment DESC
       LIMIT $limite
      ''',
      variables: [Variable<DateTime>(depuis?.toUtc())],
      readsFrom: {
        payments,
        folios,
        guests,
        reservationRooms,
        rooms,
        cashSessions,
        outlets,
        users,
      },
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          EncaissementHistorique(
            id: r.read<String>('id'),
            montant: r.read<int>('amount'),
            moyen: PaymentMethod.values.byName(r.read<String>('method')),
            remboursement: r.read<bool>('is_refund'),
            annule: r.readNullable<String>('reverses_payment_id'),
            reference: r.readNullable<String>('reference'),
            moment: r.readNullable<DateTime>('moment'),
            client: _client(r),
            chambre: r.readNullable<String>('chambre'),
            pointDeVente: r.readNullable<String>('point_de_vente'),
            agent: _nom(r, 'agent_prenom', 'agent_nom'),
          ),
      ],
    );
  }

  /// Les arrhes recues depuis [depuis] (toutes sans lui).
  Stream<List<ArrhesHistorique>> watchArrhesHistorique({DateTime? depuis}) {
    return customSelect(
      '''
      SELECT r.id, r.reference, r.deposit_amount, r.deposit_paid_at,
             g.first_name, g.last_name
        FROM reservations r
        LEFT JOIN guests g ON g.id = r.guest_id
       WHERE r.deleted_at IS NULL
         AND r.deposit_paid_at IS NOT NULL
         AND r.deposit_amount > 0
         AND (?1 IS NULL OR r.deposit_paid_at >= ?1)
       ORDER BY r.deposit_paid_at DESC
      ''',
      variables: [Variable<DateTime>(depuis?.toUtc())],
      readsFrom: {reservations, guests},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          ArrhesHistorique(
            id: r.read<String>('id'),
            reference: r.read<String>('reference'),
            montant: r.read<int>('deposit_amount'),
            moment: r.read<DateTime>('deposit_paid_at'),
            client: _client(r),
          ),
      ],
    );
  }

  /// Les depenses des journees depuis [depuis] (toutes sans elle),
  /// annulees comprises.
  Stream<List<DepenseHistorique>> watchDepensesHistorique({DateTime? depuis}) {
    return customSelect(
      '''
      SELECT e.id, e.label, e.category, e.amount, e.business_date, e.method,
             e.supplier, e.is_void, e.void_reason, e.created_at,
             u.first_name AS agent_prenom, u.last_name AS agent_nom
        FROM expenses e
        LEFT JOIN users u ON u.id = e.recorded_by
       WHERE e.deleted_at IS NULL
         AND (?1 IS NULL OR e.business_date >= ?1)
       ORDER BY e.business_date DESC, e.created_at DESC
      ''',
      variables: [
        Variable<String>(depuis == null ? null : formatIsoDate(depuis)),
      ],
      readsFrom: {expenses, users},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          DepenseHistorique(
            id: r.read<String>('id'),
            libelle: r.read<String>('label'),
            rubrique: ExpenseCategory.values.byName(r.read<String>('category')),
            montant: r.read<int>('amount'),
            jour: DateTime.parse(r.read<String>('business_date')),
            annulee: r.read<bool>('is_void'),
            motifAnnulation: r.readNullable<String>('void_reason'),
            moment: r.readNullable<DateTime>('created_at'),
            moyen: switch (r.readNullable<String>('method')) {
              null => null,
              final m => PaymentMethod.values.byName(m),
            },
            fournisseur: r.readNullable<String>('supplier'),
            agent: _nom(r, 'agent_prenom', 'agent_nom'),
          ),
      ],
    );
  }

  /// Les caisses ouvertes depuis [depuis] (toutes sans lui), et celles
  /// encore ouvertes, les plus recentes d'abord.
  Stream<List<CaisseHistorique>> watchCaissesHistorique({DateTime? depuis}) {
    return customSelect(
      '''
      SELECT c.id, c.opened_at, c.opening_float, c.closed_at,
             c.counted_amount, c.expected_amount, c.variance,
             c.received_at, c.received_amount,
             o.label AS point_de_vente,
             a.first_name AS agent_prenom, a.last_name AS agent_nom,
             r.first_name AS recu_prenom, r.last_name AS recu_nom
        FROM cash_sessions c
        LEFT JOIN outlets o ON o.id = c.outlet_id
        LEFT JOIN users a   ON a.id = c.user_id
        LEFT JOIN users r   ON r.id = c.received_by
       WHERE c.deleted_at IS NULL
         AND (?1 IS NULL OR c.opened_at >= ?1 OR c.status = 'OPEN'
              OR c.closed_at >= ?1)
       ORDER BY c.opened_at DESC
      ''',
      variables: [Variable<DateTime>(depuis?.toUtc())],
      readsFrom: {cashSessions, outlets, users},
    ).watch().map(
      (rangs) => [
        for (final c in rangs)
          CaisseHistorique(
            id: c.read<String>('id'),
            pointDeVente: c.readNullable<String>('point_de_vente'),
            agent: _nom(c, 'agent_prenom', 'agent_nom'),
            ouverteLe: c.readNullable<DateTime>('opened_at'),
            fond: c.read<int>('opening_float'),
            fermeeLe: c.readNullable<DateTime>('closed_at'),
            compte: c.readNullable<int>('counted_amount'),
            attendu: c.read<int>('expected_amount'),
            ecart: c.read<int>('variance'),
            recuLe: c.readNullable<DateTime>('received_at'),
            recu: c.readNullable<int>('received_amount'),
            recuPar: _nom(c, 'recu_prenom', 'recu_nom'),
          ),
      ],
    );
  }

  /// Les factures emises ou annulees depuis [depuis] (toutes sans lui).
  Stream<List<FactureHistorique>> watchFacturesHistorique({DateTime? depuis}) {
    return customSelect(
      '''
      SELECT i.id, COALESCE(i.number, i.provisional_number, '') AS numero,
             i.total, i.status, i.issued_at, i.cancelled_at, i.cancel_reason,
             COALESCE(i.bill_to_name,
                      TRIM(COALESCE(g.first_name, '') || ' ' ||
                           COALESCE(g.last_name, ''))) AS client
        FROM invoices i
        LEFT JOIN guests g ON g.id = i.guest_id
       WHERE i.deleted_at IS NULL
         AND i.issued_at IS NOT NULL
         AND (?1 IS NULL OR i.issued_at >= ?1 OR i.cancelled_at >= ?1)
       ORDER BY i.issued_at DESC
      ''',
      variables: [Variable<DateTime>(depuis?.toUtc())],
      readsFrom: {invoices, guests},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          FactureHistorique(
            id: r.read<String>('id'),
            numero: r.read<String>('numero'),
            total: r.read<int>('total'),
            statut: InvoiceStatus.values.byName(r.read<String>('status')),
            emiseLe: r.readNullable<DateTime>('issued_at'),
            annuleeLe: r.readNullable<DateTime>('cancelled_at'),
            motifAnnulation: r.readNullable<String>('cancel_reason'),
            client: switch (r.readNullable<String>('client')?.trim()) {
              null || '' => null,
              final c => c,
            },
          ),
      ],
    );
  }

  /// Le client d'une ardoise ou d'une reservation, sinon le nom de
  /// l'ardoise du comptoir.
  static String? _client(QueryRow r) {
    final n =
        '${r.readNullable<String>('first_name') ?? ''} '
                '${r.readNullable<String>('last_name') ?? ''}'
            .trim();
    if (n.isNotEmpty) return n;
    if (!r.data.containsKey('tab_number')) return null;
    final etiquette = r.readNullable<String>('tab_label');
    final numero = r.readNullable<int>('tab_number');
    return etiquette ??
        (numero == null ? null : 'Client divers n°$numero');
  }

  static String? _nom(QueryRow r, String prenom, String nom) {
    final n =
        '${r.readNullable<String>(prenom) ?? ''} '
                '${r.readNullable<String>(nom) ?? ''}'
            .trim();
    return n.isEmpty ? null : n;
  }
}
