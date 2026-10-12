/// Les ardoises du comptoir : consommer d'abord, payer a la fin.
///
/// Decision du 12 octobre. Au bar, un client prend une biere, puis un jus,
/// et demande sa note en partant. Son ardoise appartient au point de vente et
/// porte un numero (« Passage n°3 ») ; un client loge a la sienne, a son nom.
/// Elle se termine de trois facons : payee au comptoir, portee a la chambre,
/// ou annulee avec un motif par un responsable.
///
/// Tout se fait hors ligne : chaque geste s'ecrit ici et part dans la file
/// d'envoi (`POST /outlet-tabs...`). Ce que le serveur refuserait -- caisse
/// fermee, paiement qui ne couvre pas le total, plafond depasse -- est refuse
/// ici d'abord : un refus par la file la bloquerait, et tout ce qui attend
/// derriere avec elle.
library;

import 'package:drift/drift.dart';

import '../../core/business_day.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'cash_repository.dart';
import 'folio_repository.dart';
import 'guest_repository.dart' show codeFromId;
import 'outbox.dart';

/// Ou en est une ardoise.
enum EtatArdoise {
  /// Ouverte : le client consomme, ou n'a pas encore paye.
  aPayer,

  /// Payee au comptoir.
  payee,

  /// Portee sur la chambre : le client paiera a son depart.
  enChambre,

  /// Annulee par un responsable : client parti sans payer.
  annulee,
}

/// Une ardoise, telle que le comptoir la montre sur sa tuile.
class Ardoise {
  const Ardoise({
    required this.id,
    required this.pointDeVente,
    required this.numero,
    required this.etat,
    required this.total,
    required this.reste,
    required this.lignes,
    this.clientId,
    this.client,
    this.chambre,
    this.ouverteLe,
    this.fermeeLe,
  });

  final String id;
  final String pointDeVente;

  /// « Passage n°3 ». Nul pour une ardoise venue d'un serveur plus ancien.
  final int? numero;
  final EtatArdoise etat;

  /// Ce qui a ete consomme (lignes annulees exclues).
  final int total;

  /// Ce qui reste a payer.
  final int reste;
  final int lignes;

  /// Le client loge, s'il en est un.
  final String? clientId;
  final String? client;

  /// Sa chambre, s'il y loge encore.
  final String? chambre;
  final DateTime? ouverteLe;
  final DateTime? fermeeLe;

  bool get ouverte => etat == EtatArdoise.aPayer;

  /// Ce qu'affiche la tuile : la chambre et le nom, ou le numero de passage.
  String get titre {
    if (client != null) {
      return chambre == null ? client! : '$chambre · $client';
    }
    return numero == null ? 'Client de passage' : 'Passage n°$numero';
  }
}

/// Une consommation de l'ardoise.
class LigneArdoise {
  const LigneArdoise({
    required this.id,
    required this.libelle,
    required this.quantite,
    required this.montant,
    required this.annulee,
    this.saisieLe,
  });

  final String id;
  final String libelle;
  final int quantite;
  final int montant;
  final bool annulee;
  final DateTime? saisieLe;
}

class OutletTabRepository with OutboxWriter {
  OutletTabRepository(this.db, {this.hotelId = FolioRepository.defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  // --- Lectures -----------------------------------------------------------------

  /// Les ardoises d'un point de vente, les ouvertes d'abord, puis les plus
  /// recentes. Les filtres (en cours, payees aujourd'hui, toutes) sont ceux
  /// de l'ecran.
  Stream<List<Ardoise>> watchArdoises(String outletId) {
    return db
        .customSelect(
          '''
      SELECT f.id, f.outlet_id, f.tab_number, f.status, f.guest_id,
             f.charges_total, f.payments_total, f.balance,
             f.opened_at, f.closed_at,
             g.first_name, g.last_name,
             (SELECT rm.number
                FROM reservation_rooms rr
                JOIN reservations r ON r.id = rr.reservation_id
                JOIN rooms rm       ON rm.id = rr.room_id
               WHERE r.guest_id = f.guest_id
                 AND rr.status = 'CHECKED_IN'
                 AND rr.deleted_at IS NULL
               LIMIT 1) AS chambre,
             (SELECT COUNT(*) FROM folio_items i
               WHERE i.folio_id = f.id AND i.deleted_at IS NULL) AS lignes,
             (SELECT COUNT(*) FROM folio_items i
               WHERE i.folio_id = f.id AND i.deleted_at IS NULL
                 AND i.is_void = 1) AS annulees
        FROM folios f
        LEFT JOIN guests g ON g.id = f.guest_id
       WHERE f.outlet_id = ?1 AND f.deleted_at IS NULL
       ORDER BY (f.status = 'OPEN') DESC, f.opened_at DESC
      ''',
          variables: [Variable.withString(outletId)],
          readsFrom: {
            db.folios,
            db.folioItems,
            db.guests,
            db.reservationRooms,
            db.reservations,
            db.rooms,
          },
        )
        .watch()
        .map((rows) => [for (final r in rows) _ardoise(r)]);
  }

  Ardoise _ardoise(QueryRow r) {
    final ouverte = r.read<String>('status') == FolioStatus.OPEN.name;
    final paye = r.read<int>('payments_total');
    final annulees = r.read<int>('annulees');
    final lignes = r.read<int>('lignes');
    final EtatArdoise etat;
    if (ouverte) {
      etat = EtatArdoise.aPayer;
    } else if (paye > 0) {
      etat = EtatArdoise.payee;
    } else if (annulees > 0 && annulees == lignes) {
      etat = EtatArdoise.annulee;
    } else {
      // Close, rien paye, rien d'annule : ses lignes sont parties sur la
      // chambre.
      etat = EtatArdoise.enChambre;
    }
    final prenom = r.readNullable<String>('first_name');
    final nom = r.readNullable<String>('last_name');
    return Ardoise(
      id: r.read<String>('id'),
      pointDeVente: r.read<String>('outlet_id'),
      numero: r.readNullable<int>('tab_number'),
      etat: etat,
      total: r.read<int>('charges_total'),
      reste: r.read<int>('balance'),
      lignes: lignes - annulees,
      clientId: r.readNullable<String>('guest_id'),
      client: nom == null ? null : '${prenom ?? ''} $nom'.trim(),
      chambre: r.readNullable<String>('chambre'),
      ouverteLe: r.readNullable<DateTime>('opened_at'),
      fermeeLe: r.readNullable<DateTime>('closed_at'),
    );
  }

  /// Les consommations d'une ardoise, dans l'ordre ou elles ont ete servies.
  Stream<List<LigneArdoise>> watchLignes(String ardoiseId) {
    return (db.select(db.folioItems)
          ..where((i) => i.folioId.equals(ardoiseId) & i.deletedAt.isNull())
          ..orderBy([
            (i) => OrderingTerm(expression: i.postedAt),
            (i) => OrderingTerm(expression: i.createdAt),
          ]))
        .watch()
        .map(
          (rows) => [
            for (final i in rows)
              LigneArdoise(
                id: i.id,
                libelle: i.label,
                quantite: i.quantity,
                montant: i.amount,
                annulee: i.isVoid,
                saisieLe: i.postedAt,
              ),
          ],
        );
  }

  /// L'ardoise ouverte de ce client a ce point de vente, s'il en a une : un
  /// client loge n'en a qu'une a la fois par comptoir.
  Future<String?> ardoiseOuverteDuClient(String outletId, String guestId) async {
    final f =
        await (db.select(db.folios)
              ..where(
                (f) =>
                    f.outletId.equals(outletId) &
                    f.guestId.equals(guestId) &
                    f.status.equalsValue(FolioStatus.OPEN) &
                    f.deletedAt.isNull(),
              )
              ..limit(1))
            .getSingleOrNull();
    return f?.id;
  }

  /// Les ardoises encore ouvertes d'un point de vente : (combien, ce qui
  /// reste a payer). Le versement du soir le dit avant de fermer le tiroir.
  Future<(int, int)> nonPayees(String outletId) async {
    final r = await db
        .customSelect(
          '''
      SELECT COUNT(*) AS nombre, COALESCE(SUM(balance), 0) AS reste
        FROM folios
       WHERE outlet_id = ?1 AND status = 'OPEN' AND deleted_at IS NULL
      ''',
          variables: [Variable.withString(outletId)],
          readsFrom: {db.folios},
        )
        .getSingle();
    return (r.read<int>('nombre'), r.read<int>('reste'));
  }

  /// L'ardoise ouverte du sejour de ce client : c'est la que se porte son
  /// ardoise du bar. `null` s'il est parti.
  Future<String?> ardoiseDuSejour(String guestId) async {
    final r = await db
        .customSelect(
          '''
      SELECT f.id AS id
        FROM folios f
        JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
        JOIN reservations r ON r.id = rr.reservation_id
       WHERE f.status = 'OPEN' AND f.deleted_at IS NULL
         AND rr.status = 'CHECKED_IN'
         AND COALESCE(f.guest_id, r.guest_id) = ?1
       LIMIT 1
      ''',
          variables: [Variable.withString(guestId)],
          readsFrom: {db.folios, db.reservationRooms, db.reservations},
        )
        .getSingleOrNull();
    return r?.read<String>('id');
  }

  /// Le prochain numero de passage : par point de vente et par journee
  /// hoteliere. Deux tablettes du meme bar, hors ligne au meme instant,
  /// peuvent tirer le meme numero ; l'ardoise reste distincte, seul le
  /// libelle se repete.
  Future<int> prochainNumero(String outletId, {DateTime? maintenant}) async {
    final jour = businessDayFor(maintenant ?? DateTime.now());
    final debut = DateTime(
      jour.year,
      jour.month,
      jour.day,
      heureBasculeParDefaut,
    ).toUtc();
    final max = db.folios.tabNumber.max();
    final r =
        await (db.selectOnly(db.folios)
              ..addColumns([max])
              ..where(
                db.folios.outletId.equals(outletId) &
                    db.folios.openedAt.isBiggerOrEqualValue(debut),
              ))
            .getSingle();
    return (r.read(max) ?? 0) + 1;
  }

  // --- Gestes -------------------------------------------------------------------

  /// Ouvre l'ardoise d'un client au comptoir ; rend son identifiant.
  ///
  /// Rien ne se sert sans le tiroir ouvert du point de vente (decision du 11
  /// octobre) : ouvrir une ardoise, c'est deja servir. Un client loge qui a
  /// deja une ardoise ouverte ici la retrouve, plutot que d'en avoir deux.
  Future<String> ouvrir({
    required OutletRow pointDeVente,
    required String by,
    String? guestId,
  }) async {
    await _caisseOuverte(pointDeVente, by);
    if (guestId != null) {
      final deja = await ardoiseOuverteDuClient(pointDeVente.id, guestId);
      if (deja != null) return deja;
    }

    final id = newId();
    final now = DateTime.now().toUtc();
    final numero = await prochainNumero(pointDeVente.id);
    await db.transaction(() async {
      await db
          .into(db.folios)
          .insert(
            FoliosCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              number: codeFromId(id, 'FOL'),
              type: const Value(FolioType.WALK_IN),
              status: const Value(FolioStatus.OPEN),
              outletId: Value(pointDeVente.id),
              tabNumber: Value(numero),
              guestId: Value(guestId),
              openedAt: Value(now),
              notes: Value('Ardoise n°$numero - ${pointDeVente.label}'),
              syncState: const Value(SyncState.pending),
            ),
          );
      await enqueue(
        table: 'folios',
        id: id,
        operation: SyncOp.INSERT,
        payload: {
          'id': id,
          'action': 'TAB_OPEN',
          'outlet_id': pointDeVente.id,
          'tab_number': numero,
          'guest_id': guestId,
        },
      );
    });
    return id;
  }

  /// Sert une consommation sur l'ardoise.
  ///
  /// Par `FolioRepository.addCharge` : la ligne, le plafond du client, le
  /// stock du point de vente et la file d'envoi, comme pour une
  /// consommation portee a la chambre.
  Future<void> servir({
    required OutletRow pointDeVente,
    required String ardoiseId,
    required String libelle,
    required int prixUnitaire,
    required String by,
    required ChargeCategory categorie,
    int quantite = 1,
    String? menuItemId,
    String? overrideBy,
  }) async {
    if (libelle.trim().isEmpty) {
      throw StateError('Indiquez ce qui a été consommé.');
    }
    if (prixUnitaire <= 0 || quantite <= 0) {
      throw StateError('Le montant doit être supérieur à zéro.');
    }
    await _caisseOuverte(pointDeVente, by);
    await _ouverte(ardoiseId);
    await FolioRepository(db, hotelId: hotelId).addCharge(
      folioId: ardoiseId,
      category: categorie,
      label: libelle.trim(),
      unitPrice: prixUnitaire,
      quantity: quantite,
      postedBy: by,
      sourceTable: 'outlets',
      sourceId: pointDeVente.id,
      menuItemId: menuItemId,
      overrideBy: overrideBy,
    );
  }

  /// Le client paie sa note : le total, d'un coup, dans le tiroir du point
  /// de vente. L'ardoise se clot.
  Future<void> payer({
    required OutletRow pointDeVente,
    required String ardoiseId,
    required PaymentMethod moyen,
    required String by,
  }) async {
    final caisse = await _caisseOuverte(pointDeVente, by);
    final ardoise = await _ouverte(ardoiseId);
    if (ardoise.balance <= 0) {
      throw StateError('Il n\'y a rien à payer sur cette ardoise.');
    }
    final paiementId = newId();
    final now = DateTime.now().toUtc();
    final total = ardoise.balance;
    await db.transaction(() async {
      await db
          .into(db.payments)
          .insert(
            PaymentsCompanion.insert(
              id: paiementId,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              method: moyen,
              amount: total,
              folioId: Value(ardoiseId),
              receivedBy: Value(by),
              cashSessionId: Value(caisse),
              receivedAt: Value(now),
              businessDate: Value(businessDateNow()),
              // Remonte avec le geste « payer », pas a part.
              syncState: const Value(SyncState.synced),
            ),
          );
      await FolioRepository(db, hotelId: hotelId).recalculer(ardoiseId);
      await _clore(ardoiseId, now);
      await enqueue(
        table: 'folios',
        id: ardoiseId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': ardoiseId,
          'action': 'TAB_SETTLE',
          'payment': {'id': paiementId, 'method': moyen.name, 'amount': total},
        },
      );
    });
  }

  /// Porte toute l'ardoise sur la chambre : le client paiera a son depart.
  /// Les lignes changent d'ardoise sans changer de point de vente.
  Future<void> porterALaChambre({
    required OutletRow pointDeVente,
    required String ardoiseId,
    required String ardoiseChambreId,
    String? overrideBy,
  }) async {
    if (!pointDeVente.allowsRoomCharge) {
      throw StateError(
        '${pointDeVente.label} ne porte pas sur la chambre : encaissez sur '
        'place.',
      );
    }
    final ardoise = await _ouverte(ardoiseId);
    if (ardoise.paymentsTotal != 0) {
      throw StateError(
        'Cette ardoise a déjà un paiement : elle se paie au comptoir.',
      );
    }
    final chambre =
        await (db.select(db.folios)
              ..where((f) => f.id.equals(ardoiseChambreId)))
            .getSingleOrNull();
    if (chambre == null ||
        chambre.status != FolioStatus.OPEN ||
        chambre.reservationRoomId == null) {
      throw StateError(
        'Ce séjour n\'a pas d\'ardoise ouverte : le client est parti.',
      );
    }
    final depot = FolioRepository(db, hotelId: hotelId);
    // Au nom du meme client, le plafond compte deja l'ardoise du bar : la
    // porter a sa chambre ne change pas ce qu'il doit. Pour un autre, c'est
    // une nouvelle dette, qui se controle -- comme le fait le serveur.
    if (ardoise.guestId == null || ardoise.guestId != chambre.guestId) {
      await depot.verifierSeuil(chambre.id, ardoise.balance, overrideBy);
    }
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await db.customUpdate(
        'UPDATE folio_items SET folio_id = ?1, updated_at = ?3 '
        'WHERE folio_id = ?2 AND deleted_at IS NULL',
        variables: [
          Variable.withString(chambre.id),
          Variable.withString(ardoiseId),
          Variable.withDateTime(now),
        ],
        updates: {db.folioItems},
      );
      await depot.recalculer(chambre.id);
      await depot.recalculer(ardoiseId);
      await _clore(ardoiseId, now);
      await enqueue(
        table: 'folios',
        id: ardoiseId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': ardoiseId,
          'action': 'TAB_TO_ROOM',
          'room_folio_id': chambre.id,
          'override_by': overrideBy,
        },
      );
    });
  }

  /// Le client est parti sans payer : un responsable annule l'ardoise, avec
  /// un motif. Les lignes restent, annulees : ce qui a ete servi est sorti
  /// du stock, et la trace dit qui a annule et pourquoi.
  Future<void> annuler({
    required String ardoiseId,
    required String motif,
    required String by,
  }) async {
    if (motif.trim().length < 3) {
      throw StateError('Indiquez le motif de l\'annulation.');
    }
    final ardoise = await _ouverte(ardoiseId);
    if (ardoise.paymentsTotal != 0) {
      throw StateError(
        'Cette ardoise a déjà un paiement : elle ne s\'annule pas.',
      );
    }
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(db.folioItems)..where(
            (i) =>
                i.folioId.equals(ardoiseId) &
                i.deletedAt.isNull() &
                i.isVoid.equals(false),
          ))
          .write(
            FolioItemsCompanion(
              isVoid: const Value(true),
              voidReason: Value(motif.trim()),
              voidedBy: Value(by),
              updatedAt: Value(now),
            ),
          );
      await FolioRepository(db, hotelId: hotelId).recalculer(ardoiseId);
      await _clore(ardoiseId, now);
      await enqueue(
        table: 'folios',
        id: ardoiseId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': ardoiseId,
          'action': 'TAB_CANCEL',
          'reason': motif.trim(),
        },
      );
    });
  }

  // --- Outils -------------------------------------------------------------------

  /// Le tiroir ouvert de l'agent pour ce point de vente, ou un refus.
  Future<String> _caisseOuverte(OutletRow pointDeVente, String by) async {
    final caisse = await CashRepository(
      db,
    ).openSessionId(by, outletId: pointDeVente.id);
    if (caisse == null) {
      throw StateError(
        'Ouvrez la caisse de ${pointDeVente.label} avant de servir : le '
        'point de vente est fermé.',
      );
    }
    return caisse;
  }

  Future<FolioRow> _ouverte(String ardoiseId) async {
    final f = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(ardoiseId))).getSingleOrNull();
    if (f == null || f.outletId == null) {
      throw StateError('Ardoise introuvable.');
    }
    if (f.status != FolioStatus.OPEN) {
      throw StateError('Cette ardoise est déjà close.');
    }
    return f;
  }

  Future<void> _clore(String ardoiseId, DateTime now) =>
      (db.update(db.folios)..where((f) => f.id.equals(ardoiseId))).write(
        FoliosCompanion(
          status: const Value(FolioStatus.CLOSED),
          closedAt: Value(now),
          updatedAt: Value(now),
          // La version locale fait foi tant que le geste n'est pas remonte :
          // la descente ne doit pas rouvrir l'ardoise que le serveur croit
          // encore ouverte.
          syncState: const Value(SyncState.pending),
        ),
      );
}
