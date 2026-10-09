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
import '../../repositories/settings_repository.dart' show stayCheckoutHourKey;

/// Les evenements qui font une alerte : la liste arretee avec l'hotel.
///
/// Le code est celui que le serveur garde avec le niveau choisi par
/// l'administration (`GET /settings/notification-levels`) : il ne change
/// jamais, meme si le libelle change.
enum TypeEvenement {
  envoiBloque(
    'SYNC_BLOCKED',
    'Écriture bloquée',
    'Le serveur refuse une saisie : plus rien ne remonte derrière elle.',
    'Tous les agents',
    NiveauSignal.sonoreVibration,
  ),
  chambreAFaire(
    'ROOM_TO_CLEAN',
    'Chambre à faire',
    'Un départ ou une recouche attend le ménage.',
    'La femme de chambre désignée, sinon toute l’équipe du ménage',
    NiveauSignal.sonoreVibration,
  ),
  panne(
    'MAINTENANCE',
    'Panne prioritaire ou urgente',
    'Une panne signalée haute ou urgente n’est pas réglée.',
    'La maintenance',
    NiveauSignal.sonoreVibration,
  ),
  arriveeAttendue(
    'ARRIVAL_EXPECTED',
    'Arrivée attendue',
    'Un client est attendu aujourd’hui et n’est pas encore arrivé.',
    'La réception',
    NiveauSignal.sonore,
  ),
  departDepasse(
    'LATE_DEPARTURE',
    'Départ dépassé',
    'Un client est encore dans sa chambre après l’heure de départ.',
    'La réception',
    NiveauSignal.sonore,
  ),
  transfertAValider(
    'TRANSFER_PENDING',
    'Transfert à valider',
    'Un magasin demande des produits à un autre.',
    'Qui valide les transferts de stock',
    NiveauSignal.sonore,
  ),
  stockBas(
    'LOW_STOCK',
    'Stock bas',
    'Un produit passe sous son seuil d’alerte dans un magasin.',
    'Qui suit les stocks',
    NiveauSignal.discret,
  );

  const TypeEvenement(
    this.code,
    this.libelle,
    this.description,
    this.destinataires,
    this.niveauParDefaut,
  );

  final String code;
  final String libelle;
  final String description;
  final String destinataires;
  final NiveauSignal niveauParDefaut;

  static TypeEvenement? depuisCode(String code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// Comment un evenement se signale : c'est l'administration qui choisit,
/// evenement par evenement.
enum NiveauSignal {
  /// Dans la cloche et en notification silencieuse, sans bandeau.
  discret('SILENT', 'Discret'),

  /// Bandeau et sonnerie, rappelee jusqu'a « J'ai vu ».
  sonore('SOUND', 'Sonore'),

  /// Bandeau, sonnerie et vibration.
  sonoreVibration('SOUND_VIBRATION', 'Sonore et vibration');

  const NiveauSignal(this.code, this.libelle);

  final String code;
  final String libelle;

  bool get sonne => this != discret;
  bool get vibre => this == sonoreVibration;

  static NiveauSignal? depuisCode(Object? code) {
    for (final n in values) {
      if (n.code == code) return n;
    }
    return null;
  }
}

/// La gravite d'une alerte, de la plus discrete a la plus forte : elle
/// decide de la couleur, de la sonnerie et du rythme des rappels. Le niveau
/// de l'evenement ([NiveauSignal]) decide, lui, s'il y a bruit ou pas.
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
    required this.type,
    required this.niveau,
    required this.titre,
    required this.corps,
    this.route,
    this.depuis,
  });

  final String cle;
  final TypeEvenement type;
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
      reservations,
      folioItems,
      settings,
      stockLevels,
      stockMovements,
      products,
    ]),
  );

  /// Les alertes en cours, de la plus forte a la plus discrete.
  Future<List<Alerte>> chargerAlertes(ContexteAlertes c) async {
    final alertes = [
      ...await _envoiBloque(),
      if (c.peut('housekeeping.read')) ...await _menage(c),
      if (c.peut('maintenance.read')) ...await _pannes(),
      if (c.peut('reservation.read') && c.poste) ...await _arrivees(c),
      if (c.peut('reservation.read') && c.poste) ...await _departs(c),
      if (c.peut('stock.transfer.approve')) ...await _transferts(),
      if (c.peut('stock.read')) ...await _stockBas(),
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
        type: TypeEvenement.envoiBloque,
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
          type: TypeEvenement.chambreAFaire,
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
          type: TypeEvenement.panne,
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
    // L'heure reglee dans l'administration, midi a defaut : une alerte a
    // 12 h dans un hotel qui libere les chambres a 11 h sonnerait trop tard.
    final reglage = await customSelect(
      "SELECT value FROM settings WHERE key = ?1 AND scope = 'GLOBAL' "
      'AND scope_id IS NULL AND deleted_at IS NULL LIMIT 1',
      variables: [Variable.withString(stayCheckoutHourKey)],
      readsFrom: {settings},
    ).getSingleOrNull();
    final lue = int.tryParse(reglage?.readNullable<String>('value') ?? '');
    final heureDepart =
        lue != null && lue >= 0 && lue <= 23 ? lue : heureDepartParDefaut;
    final aujourdhui = businessDayFor(c.maintenant);
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
      final jourDepart = parseIsoDate(l.read<String>('depart'))!;
      final limite = limiteDeDepart(
        jourDepart,
        heureDepart: heureDepart,
        heuresProlongees: l.read<int>('heures'),
      );
      if (!c.maintenant.isAfter(limite)) continue;
      // Une nuit de plus sans depart ni prolongation : la chambre n'est
      // peut-etre plus occupee du tout, ou le client dort sans etre facture.
      final oublie = aujourdhui.isAfter(jourDepart);
      final client = [
        l.readNullable<String>('prenom'),
        l.readNullable<String>('nom'),
      ].whereType<String>().join(' ').trim();
      alertes.add(
        Alerte(
          // La limite dans la cle : une prolongation la repousse, et son
          // depassement sonne de nouveau.
          cle: 'depart-${l.read<String>('id')}-${limite.toIso8601String()}',
          type: TypeEvenement.departDepasse,
          niveau: oublie ? NiveauAlerte.critique : NiveauAlerte.urgente,
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

  /// Les clients attendus aujourd'hui qui ne sont pas encore arrives : un
  /// par sejour, pour qu'un enregistrement fasse taire le sien seulement.
  Future<List<Alerte>> _arrivees(ContexteAlertes c) async {
    final lignes = await customSelect(
      '''
      SELECT rr.id AS id, rr.created_at AS moment, rr.departure_date AS depart,
             r.number AS chambre, t.label AS type_chambre,
             g.first_name AS prenom, g.last_name AS nom
        FROM reservation_rooms rr
        JOIN reservations d     ON d.id = rr.reservation_id
        LEFT JOIN rooms r       ON r.id = rr.room_id
        LEFT JOIN room_types t  ON t.id = rr.room_type_id
        LEFT JOIN guests g      ON g.id = d.guest_id
       WHERE rr.deleted_at IS NULL
         AND d.deleted_at IS NULL
         AND rr.status IN ('PENDING','CONFIRMED')
         AND rr.arrival_date = ?1
       ORDER BY g.last_name, rr.id
      ''',
      variables: [Variable.withString(businessDateNow(at: c.maintenant))],
      readsFrom: {reservationRooms, reservations, rooms, roomTypes, guests},
    ).get();
    final jour = parseIsoDate(businessDateNow(at: c.maintenant))!;
    return [
      for (final l in lignes)
        Alerte(
          cle: 'arrivee-${l.read<String>('id')}',
          type: TypeEvenement.arriveeAttendue,
          niveau: NiveauAlerte.info,
          titre: 'Arrivée attendue : ${_client(l, 'Un client')}',
          corps: [
            if (l.readNullable<String>('chambre') case final ch?)
              'Chambre $ch'
            else
              ?l.readNullable<String>('type_chambre'),
            _nuits(jour, parseIsoDate(l.read<String>('depart'))),
          ].whereType<String>().join(', '),
          route: '/',
          depuis: l.readNullable<DateTime>('moment'),
        ),
    ];
  }

  /// Les transferts entre magasins qui attendent une validation.
  Future<List<Alerte>> _transferts() async {
    final lignes = await customSelect(
      '''
      SELECT m.id AS id, m.quantity AS quantite, m.moved_at AS moment,
             p.label AS produit,
             src.label AS depuis, dst.label AS vers
        FROM stock_movements m
        JOIN products p          ON p.id = m.product_id
        JOIN stock_locations src ON src.id = m.stock_location_id
        JOIN stock_locations dst ON dst.id = m.counterpart_location_id
       WHERE m.deleted_at IS NULL
         AND m.type = 'TRANSFER' AND m.status = 'PENDING'
       ORDER BY m.moved_at
      ''',
      readsFrom: {stockMovements, products, stockLocations},
    ).get();
    return [
      for (final l in lignes)
        Alerte(
          cle: 'transfert-${l.read<String>('id')}',
          type: TypeEvenement.transfertAValider,
          niveau: NiveauAlerte.urgente,
          titre:
              'Transfert à valider : ${l.read<int>('quantite')} '
              '${l.read<String>('produit')}',
          corps:
              'De « ${l.read<String>('depuis')} » vers '
              '« ${l.read<String>('vers')} ». Rien ne bouge avant la '
              'validation.',
          route: '/stocks',
          depuis: l.readNullable<DateTime>('moment'),
        ),
    ];
  }

  /// Les produits sous leur seuil, magasin par magasin. L'economat porte
  /// tous les produits : un produit qu'il n'a jamais recu y est a zero.
  Future<List<Alerte>> _stockBas() async {
    final lignes = await customSelect(
      '''
      SELECT p.id AS produit, p.label AS libelle,
             p.min_stock AS seuil, s.id AS lieu, s.label AS magasin,
             COALESCE(l.quantity, 0) AS quantite
        FROM products p
        JOIN stock_locations s ON s.deleted_at IS NULL AND s.is_active = 1
        LEFT JOIN stock_levels l ON l.product_id = p.id
                                AND l.stock_location_id = s.id
                                AND l.deleted_at IS NULL
       WHERE p.deleted_at IS NULL
         AND p.is_active = 1
         AND p.min_stock > 0
         AND (l.id IS NOT NULL OR s.is_central = 1)
         AND COALESCE(l.quantity, 0) < p.min_stock
       ORDER BY p.label, s.sort_order
      ''',
      readsFrom: {products, stockLocations, stockLevels},
    ).get();
    return [for (final l in lignes) _alerteStock(l)];
  }

  static Alerte _alerteStock(QueryRow l) {
    final quantite = l.read<int>('quantite');
    final magasin = l.read<String>('magasin');
    final seuil = l.read<int>('seuil');
    return Alerte(
      // Le magasin dans la cle : le bar a court ne fait pas taire l'economat.
      cle: 'stock-${l.read<String>('produit')}-${l.read<String>('lieu')}',
      type: TypeEvenement.stockBas,
      niveau: NiveauAlerte.info,
      titre: quantite <= 0
          ? 'Rupture : ${l.read<String>('libelle')}'
          : 'Stock bas : ${l.read<String>('libelle')}',
      corps: quantite <= 0
          ? 'Plus rien à « $magasin » (seuil $seuil). Pensez à '
                'réapprovisionner.'
          : '$quantite restant${quantite > 1 ? 's' : ''} à « $magasin », '
                'sous le seuil de $seuil.',
      route: '/stocks',
    );
  }

  static String _client(QueryRow l, String defaut) {
    final nom = [
      l.readNullable<String>('prenom'),
      l.readNullable<String>('nom'),
    ].whereType<String>().join(' ').trim();
    return nom.isEmpty ? defaut : nom;
  }

  static String? _nuits(DateTime arrivee, DateTime? depart) {
    if (depart == null) return null;
    final n = depart.difference(arrivee).inDays;
    if (n <= 0) return null;
    return n == 1 ? '1 nuit' : '$n nuits';
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
