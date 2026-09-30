/// L'ardoise du client : charges, encaissements, cloture (F1.4).
///
/// Le folio est le centre de la facturation. Toute consommation y atterrit —
/// une nuitee, un diner, une bouteille du minibar — et la facture n'est
/// qu'un gel du folio a un instant donne. C'est la decision structurante n°3
/// du projet.
library;

import 'package:drift/drift.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'cash_repository.dart';
import 'outbox.dart';

/// Une ardoise, telle qu'affichee dans la liste des factures.
class FolioSummary {
  const FolioSummary({
    required this.id,
    required this.number,
    required this.status,
    required this.guestName,
    required this.chargesTotal,
    required this.paymentsTotal,
    required this.balance,
    this.roomNumber,
  });

  final String id;
  final String number;
  final FolioStatus status;
  final String guestName;
  final int chargesTotal;
  final int paymentsTotal;

  /// Ce qui reste du. Positif : le client doit ; negatif : on lui doit.
  final int balance;

  final String? roomNumber;

  bool get isSettled => balance == 0;
  bool get isOpen => status == FolioStatus.OPEN;
}

class FolioRepository with OutboxWriter {
  FolioRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  /// Les ardoises, en flux continu.
  Stream<List<FolioSummary>> watchFolios({FolioStatus? status}) {
    return db
        .customSelect(
          '''
      SELECT f.id, f.number, f.status, f.charges_total, f.payments_total,
             f.balance,
             g.first_name, g.last_name,
             ch.number AS room_number
        FROM folios f
        LEFT JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
        LEFT JOIN reservations res     ON res.id = rr.reservation_id
        LEFT JOIN guests g             ON g.id = COALESCE(f.guest_id, res.guest_id)
        LEFT JOIN rooms ch             ON ch.id = rr.room_id
       WHERE f.deleted_at IS NULL AND f.hotel_id = ?1
       ORDER BY f.status, f.number DESC
      ''',
          variables: [Variable.withString(hotelId)],
          readsFrom: {
            db.folios,
            db.reservationRooms,
            db.reservations,
            db.guests,
            db.rooms,
          },
        )
        .watch()
        .map((rows) {
          final all = rows.map((r) {
            final first = r.read<String?>('first_name');
            final last = r.read<String?>('last_name');
            return FolioSummary(
              id: r.read<String>('id'),
              number: r.read<String>('number'),
              status: FolioStatus.values.byName(r.read<String>('status')),
              // Une ardoise de passage n'a pas de client rattache : elle
              // existe quand meme, il faut l'afficher.
              guestName: (first == null || last == null)
                  ? 'Client de passage'
                  : '$first $last',
              chargesTotal: r.read<int>('charges_total'),
              paymentsTotal: r.read<int>('payments_total'),
              balance: r.read<int>('balance'),
              roomNumber: r.read<String?>('room_number'),
            );
          });
          if (status == null) return all.toList();
          return all.where((f) => f.status == status).toList();
        });
  }

  /// Les lignes d'une ardoise, de la plus recente a la plus ancienne.
  Stream<List<FolioItemRow>> watchItems(String folioId) {
    return (db.select(db.folioItems)
          ..where((i) => i.folioId.equals(folioId) & i.deletedAt.isNull())
          ..orderBy([(i) => OrderingTerm.desc(i.createdAt)]))
        .watch();
  }

  /// Les encaissements d'une ardoise.
  Stream<List<PaymentRow>> watchPayments(String folioId) {
    return (db.select(db.payments)
          ..where((p) => p.folioId.equals(folioId) & p.deletedAt.isNull())
          ..orderBy([(p) => OrderingTerm.desc(p.createdAt)]))
        .watch();
  }

  /// L'ardoise ouverte d'un sejour, s'il y en a une.
  Future<FolioRow?> openFolioForStay(String stayLineId) {
    return (db.select(db.folios)
          ..where(
            (f) =>
                f.reservationRoomId.equals(stayLineId) &
                f.status.equalsValue(FolioStatus.OPEN) &
                f.deletedAt.isNull(),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// Porte une charge a l'ardoise.
  ///
  /// Les totaux du folio sont materialises et recalcules ici, dans la meme
  /// transaction : un solde qui se recalculerait a l'affichage divergerait du
  /// jour ou deux ecrans le liraient au meme instant.
  Future<void> addCharge({
    required String folioId,
    required ChargeCategory category,
    required String label,
    required int unitPrice,
    int quantity = 1,
    String? postedBy,
    String? sourceTable,
    String? sourceId,
    String? businessDate,
    String? overrideBy,
  }) async {
    final id = newId();
    final now = DateTime.now().toUtc();
    final amount = unitPrice * quantity;

    await _verifierSeuil(folioId, amount, overrideBy);
    // Une nuitee appartient a SA journee, pas a celle ou on la porte : porter
    // deux nuits d'un coup au depart ne doit pas gonfler le chiffre d'affaires
    // du jour de deux nuits.
    final journee = businessDate ?? businessDateNow();

    await db.transaction(() async {
      await db
          .into(db.folioItems)
          .insert(
            FolioItemsCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              folioId: folioId,
              category: category,
              label: label.trim(),
              quantity: Value(quantity),
              unitPrice: Value(unitPrice),
              amount: Value(amount),
              businessDate: journee,
              overrideBy: Value(overrideBy),
              sourceTable: Value(sourceTable),
              sourceId: Value(sourceId),
              postedBy: Value(postedBy),
              syncState: const Value(SyncState.pending),
            ),
          );

      await _recomputeTotals(folioId);

      await enqueue(
        table: 'folio_items',
        id: id,
        operation: SyncOp.INSERT,
        payload: {
          'id': id,
          'folio_id': folioId,
          'category': category.name,
          'label': label.trim(),
          'quantity': quantity,
          'unit_price': unitPrice,
          'amount': amount,
          'business_date': journee,
          'source_table': sourceTable,
          'source_id': sourceId,
          'posted_by': postedBy,
          // Sans lui, le serveur refuserait une charge que la tablette a
          // acceptee : elle a vu l'autorisation, lui non.
          'override_by': overrideBy,
        },
      );
    });
  }

  /// Le seuil de consommation du client (`guests.credit_limit`).
  ///
  /// **Verifie ici, avant d'ecrire.** Le serveur le controle aussi et repond
  /// 409 -- mais un refus qui arrive par la file d'envoi la **bloque**, avec
  /// tout ce qui attend derriere : check-ins, encaissements, menage. Le
  /// comptoir se retrouverait avec une tablette paralysee sans comprendre
  /// pourquoi. Refuser tot, poliment, garde le serveur comme simple filet.
  ///
  /// Les regles sont celles du serveur, a la lettre :
  ///
  /// - un seuil a `0` veut dire **pas de limite**, pas « tout refuser » ;
  /// - on compare le solde **apres** la charge : atteindre exactement le
  ///   seuil est permis, le depasser d'un franc ne l'est pas ;
  /// - seules les charges qui augmentent le solde sont controlees, donc ni
  ///   une remise ni des arrhes ;
  /// - un responsable peut autoriser le depassement, et son nom reste sur la
  ///   ligne. Le seuil n'est pas un blocage, c'est une autorisation.
  ///
  /// Leve une [StateError] dont le message est fait pour etre lu au
  /// telephone : c'est ce que l'agent va repeter a son responsable.
  Future<void> _verifierSeuil(
    String folioId,
    int amount,
    String? overrideBy,
  ) async {
    if (amount <= 0 || overrideBy != null) return;

    final ligne = await db
        .customSelect(
          """
      SELECT f.balance AS balance, COALESCE(g.credit_limit, 0) AS seuil
        FROM folios f
        LEFT JOIN guests g ON g.id = f.guest_id
       WHERE f.id = ?1
      """,
          variables: [Variable.withString(folioId)],
          readsFrom: {db.folios, db.guests},
        )
        .getSingleOrNull();
    if (ligne == null) return;

    final seuil = ligne.read<int>('seuil');
    if (seuil <= 0) return;

    final solde = ligne.read<int>('balance');
    final apres = solde + amount;
    if (apres <= seuil) return;

    throw StateError(
      'Seuil depasse : solde ${formatAmount(solde)} + ${formatAmount(amount)} '
      '= ${formatAmount(apres)}, seuil ${formatAmount(seuil)}, '
      'depassement ${formatAmount(apres - seuil)}. '
      'Un responsable doit autoriser.',
    );
  }

  /// Enregistre un encaissement (F1.4 : especes, carte, virement, Mobile
  /// Money).
  ///
  /// Refuse ce qui ne peut pas etre de l'argent recu : une ardoise close, un
  /// montant nul ou negatif, et surtout **plus que ce qui reste du**. Sans ce
  /// dernier controle on encaissait la meme facture deux fois -- rien ne
  /// plantait, le solde passait simplement en negatif, et l'ecart ne se
  /// serait vu qu'a la caisse en fin de service, sans moyen de savoir quel
  /// client avait trop paye.
  ///
  /// Un client qui tend 60 000 pour une note de 50 000 fait enregistrer
  /// 50 000 : les 10 000 rendus sont de la manipulation d'especes, pas une
  /// ligne d'ardoise.
  ///
  /// Leve une [StateError] dont le message est fait pour etre montre tel quel.
  Future<void> addPayment({
    required String folioId,
    required PaymentMethod method,
    required int amount,
    String? reference,
    String? receivedBy,
  }) async {
    final id = newId();
    final now = DateTime.now().toUtc();
    final businessDate = businessDateNow();

    await db.transaction(() async {
      // Lu dans la transaction : le solde ne doit pas pouvoir bouger entre la
      // verification et l'ecriture.
      final folio = await (db.select(
        db.folios,
      )..where((f) => f.id.equals(folioId))).getSingleOrNull();

      if (folio == null) {
        throw StateError('Ardoise introuvable.');
      }
      if (folio.status != FolioStatus.OPEN) {
        throw StateError(
          'L\'ardoise ${folio.number} est close : elle n\'accepte plus '
          'd\'encaissement.',
        );
      }
      if (amount <= 0) {
        throw StateError('Le montant doit etre superieur a zero.');
      }
      if (folio.balance <= 0) {
        throw StateError(
          'L\'ardoise ${folio.number} est deja soldee — il n\'y a rien a '
          'encaisser.',
        );
      }
      if (amount > folio.balance) {
        throw StateError(
          'Il ne reste que ${formatAmount(folio.balance)} a encaisser sur '
          'l\'ardoise ${folio.number}.',
        );
      }

      await db
          .into(db.payments)
          .insert(
            PaymentsCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              folioId: Value(folioId),
              method: method,
              amount: amount,
              reference: Value(reference),
              receivedBy: Value(receivedBy),
              // Rattache a la caisse ouverte de celui qui encaisse. Sans ce
              // lien, l'argent existe et n'appartient a personne : l'attendu
              // de fin de service ne peut pas se calculer, et l'ecart ne veut
              // plus rien dire. Le serveur fait le meme rattachement de son
              // cote, a partir de l'utilisateur du jeton.
              cashSessionId: Value(
                receivedBy == null
                    ? null
                    : await CashRepository(db).openSessionId(receivedBy),
              ),
              receivedAt: Value(now),
              businessDate: Value(businessDate),
              syncState: const Value(SyncState.pending),
            ),
          );

      await _recomputeTotals(folioId);

      await enqueue(
        table: 'payments',
        id: id,
        operation: SyncOp.INSERT,
        payload: {
          'id': id,
          'hotel_id': hotelId,
          'folio_id': folioId,
          'method': method.name,
          'amount': amount,
          'reference': reference,
          'received_by': receivedBy,
          'business_date': businessDate,
        },
      );
    });
  }

  /// Porte au folio les nuits du sejour qui n'y sont pas encore.
  ///
  /// Sans cet appel, un client repart en payant ses consommations et **zero
  /// franc de chambre** : le check-in ouvre l'ardoise mais n'y met rien.
  /// C'est le defaut le plus couteux possible, parce qu'il ne fait rien
  /// planter -- il fait juste perdre l'essentiel du chiffre d'affaires en
  /// silence.
  ///
  /// Une ligne par nuit, comme le prevoit le modele (`stay_nights` : *une
  /// ligne par nuit, avec son prix*). Deux nuits font deux lignes, ce qui
  /// permet d'en annuler une sans toucher aux autres.
  ///
  /// Idempotent : les nuits deja portees sont reconnues a leur `sourceId` et
  /// ne sont pas doublees. On peut donc l'appeler autant de fois qu'on veut,
  /// et notamment a chaque ouverture de l'ardoise.
  Future<int> postStayNights({
    required String folioId,
    required String stayLineId,
    String? postedBy,
  }) async {
    final line = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(stayLineId))).getSingleOrNull();
    if (line == null) return 0;

    final arrival = parseIsoDate(line.arrivalDate);
    final departure = parseIsoDate(line.departureDate);
    if (arrival == null || departure == null) return 0;

    // Les nuits deja portees, reconnues a leur source.
    final existing =
        await (db.select(db.folioItems)..where(
              (i) =>
                  i.folioId.equals(folioId) &
                  i.sourceTable.equals('stay_nights') &
                  i.deletedAt.isNull(),
            ))
            .get();
    final already = existing.map((i) => i.sourceId).toSet();

    var posted = 0;
    // Intervalle semi-ouvert : un sejour du 12 au 15 occupe les nuits du 12,
    // 13 et 14. La nuit du depart n'existe pas.
    for (
      var d = arrival;
      d.isBefore(departure);
      d = d.add(const Duration(days: 1))
    ) {
      final nightId = '$stayLineId:${formatIsoDate(d)}';
      if (already.contains(nightId)) continue;

      await addCharge(
        folioId: folioId,
        category: ChargeCategory.ROOM,
        label: 'Nuitee du ${formatShortDate(d)}',
        unitPrice: line.nightlyRate,
        postedBy: postedBy,
        sourceTable: 'stay_nights',
        sourceId: nightId,
        businessDate: formatIsoDate(d),
      );
      posted++;
    }
    return posted;
  }

  /// Clot l'ardoise.
  ///
  /// Refuse tant que le solde n'est pas nul : une ardoise close avec un
  /// impaye est une creance que plus personne ne verra.
  Future<void> close(String folioId, {String? by}) async {
    final folio = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(folioId))).getSingle();

    if (folio.balance != 0) {
      throw StateError(
        'Solde non nul (${formatAmount(folio.balance)}) : '
        'encaisser avant de clore.',
      );
    }

    final now = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(db.folios)..where((f) => f.id.equals(folioId))).write(
        FoliosCompanion(
          status: const Value(FolioStatus.CLOSED),
          updatedAt: Value(now),
          updatedBy: Value(by),
          syncState: const Value(SyncState.pending),
        ),
      );
      // CORRIGE (traçabilité, exigence 6.2) : 'updated_by' ajoute au
      // payload. La colonne locale updatedBy etait deja remplie
      // (ci-dessus), mais l'envoi au serveur l'omettait.
      await enqueue(
        table: 'folios',
        id: folioId,
        operation: SyncOp.UPDATE,
        payload: {'id': folioId, 'status': 'CLOSED', 'updated_by': by},
      );
    });
  }

  /// Fait de l'ardoise du serveur la seule ardoise du sejour.
  ///
  /// Le cas : un sejour deja arrive sur le serveur (autre tablette, ou check-in
  /// refait ici) recoit le check-in de cette tablette. Le serveur garde son
  /// ardoise et ignore celle que la tablette proposait. Sans adoption, la
  /// tablette continuait de porter consommations et encaissements sur une
  /// ardoise que le serveur ne connait pas : chaque envoi repondait 404 et
  /// bloquait la file, avec tout ce qui attendait derriere.
  ///
  /// En une transaction : tout ce qui pointait sur l'ardoise locale passe sur
  /// celle du serveur, les ecritures encore en file sont readressees, et
  /// l'ardoise locale disparait. Il ne reste qu'une ardoise par sejour.
  Future<void> adoptServerFolio({
    required String localId,
    required String serverId,
  }) async {
    if (localId == serverId) return;

    await db.transaction(() async {
      final local = await (db.select(
        db.folios,
      )..where((f) => f.id.equals(localId))).getSingleOrNull();
      if (local == null) return;

      final serveur = await (db.select(
        db.folios,
      )..where((f) => f.id.equals(serverId))).getSingleOrNull();
      if (serveur == null) {
        // Pas encore descendue : la locale lui sert de modele. Le serveur la
        // connait deja, rien a remonter.
        await db
            .into(db.folios)
            .insert(
              local.copyWith(id: serverId, syncState: SyncState.synced),
            );
      }

      // Avant la suppression : supprimer l'ardoise emporterait ses
      // consommations (`onDelete: cascade`).
      final vars = [Variable.withString(serverId), Variable.withString(localId)];
      await db.customUpdate(
        'UPDATE folio_items SET folio_id = ?1 WHERE folio_id = ?2',
        variables: vars,
        updates: {db.folioItems},
      );
      await db.customUpdate(
        'UPDATE payments SET folio_id = ?1 WHERE folio_id = ?2',
        variables: vars,
        updates: {db.payments},
      );
      await db.customUpdate(
        'UPDATE invoices SET folio_id = ?1 WHERE folio_id = ?2',
        variables: vars,
        updates: {db.invoices},
      );
      await db.customUpdate(
        'UPDATE orders SET folio_id = ?1 WHERE folio_id = ?2',
        variables: vars,
        updates: {db.orders},
      );
      await (db.delete(db.folios)..where((f) => f.id.equals(localId))).go();
      await _recomputeTotals(serverId);

      // Les ecritures qui attendent encore portent l'ancienne adresse :
      // readressees, elles partent vers une ardoise que le serveur connait.
      await db.customUpdate(
        '''
        UPDATE outbox_entries
           SET payload = json_set(payload, '\$.folio_id', ?1)
         WHERE status <> 'ACKED'
           AND json_extract(payload, '\$.folio_id') = ?2
        ''',
        variables: vars,
        updates: {db.outboxEntries},
      );
      await db.customUpdate(
        '''
        UPDATE outbox_entries
           SET entity_id = ?1,
               payload = json_set(payload, '\$.id', ?1)
         WHERE status <> 'ACKED'
           AND entity_table = 'folios'
           AND entity_id = ?2
        ''',
        variables: vars,
        updates: {db.outboxEntries},
      );
    });
  }

  /// Remplace une charge locale par celle que le serveur a gardee.
  ///
  /// Le cas : deux tablettes ont chacune porte les nuits du meme sejour, puis
  /// leurs ardoises se sont rejointes (voir `adoptServerFolio`). Le serveur,
  /// qui tient le registre des nuits, n'en compte qu'une et designe la
  /// charge deja portee. Sans ce remplacement, la tablette garderait sa copie
  /// en plus de celle du serveur, et afficherait la chambre facturee deux
  /// fois.
  Future<void> adoptServerCharge({
    required String localId,
    required String serverId,
  }) async {
    if (localId == serverId) return;

    await db.transaction(() async {
      final local = await (db.select(
        db.folioItems,
      )..where((i) => i.id.equals(localId))).getSingleOrNull();
      if (local == null) return;

      final dejaLa = await (db.select(
        db.folioItems,
      )..where((i) => i.id.equals(serverId))).getSingleOrNull();
      if (dejaLa == null) {
        await db
            .into(db.folioItems)
            .insert(
              local.copyWith(id: serverId, syncState: SyncState.synced),
            );
      }

      final vars = [Variable.withString(serverId), Variable.withString(localId)];
      await db.customUpdate(
        'UPDATE invoice_lines SET folio_item_id = ?1 WHERE folio_item_id = ?2',
        variables: vars,
        updates: {db.invoiceLines},
      );
      await db.customUpdate(
        '''
        UPDATE outbox_entries SET entity_id = ?1
         WHERE status <> 'ACKED'
           AND entity_table = 'folio_items'
           AND entity_id = ?2
        ''',
        variables: vars,
        updates: {db.outboxEntries},
      );
      await (db.delete(db.folioItems)..where((i) => i.id.equals(localId))).go();
      await _recomputeTotals(local.folioId);
    });
  }

  /// Recalcule charges, encaissements et solde depuis les lignes.
  ///
  /// En SQL et non en Dart : c'est SQLite qui fait la somme, donc le resultat
  /// ne depend pas de ce que l'application avait en memoire.
  Future<void> _recomputeTotals(String folioId) async {
    await db.customUpdate(
      '''
      UPDATE folios
         SET charges_total = COALESCE((SELECT SUM(amount) FROM folio_items
                                        WHERE folio_id = ?1
                                          AND deleted_at IS NULL), 0),
             payments_total = COALESCE((SELECT SUM(amount) FROM payments
                                         WHERE folio_id = ?1
                                           AND deleted_at IS NULL
                                           AND is_refund = 0), 0),
             balance = COALESCE((SELECT SUM(amount) FROM folio_items
                                  WHERE folio_id = ?1
                                    AND deleted_at IS NULL), 0)
                     - COALESCE((SELECT SUM(amount) FROM payments
                                  WHERE folio_id = ?1
                                    AND deleted_at IS NULL
                                    AND is_refund = 0), 0)
       WHERE id = ?1
      ''',
      // `customUpdate` et non `customStatement` : le second ecrit sans
      // prevenir personne. Le solde changeait en base et tout ecran qui le
      // lisait gardait sa valeur d'avant, jusqu'a ce qu'autre chose reveille
      // le flux. `updates` est ce qui fait repeindre.
      variables: [Variable.withString(folioId)],
      updates: {db.folios},
    );
  }
}
