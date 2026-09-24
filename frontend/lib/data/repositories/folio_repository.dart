/// L'ardoise du client : charges, encaissements, cloture (F1.4).
///
/// Le folio est le centre de la facturation. Toute consommation y atterrit —
/// une nuitee, un diner, une bouteille du minibar — et la facture n'est
/// qu'un gel du folio a un instant donne. C'est la decision structurante n°3
/// du projet.
library;

import 'package:drift/drift.dart';

import '../../core/formats.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
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
          readsFrom: {db.folios, db.reservationRooms, db.reservations, db.guests, db.rooms},
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
  }) async {
    final id = newId();
    final now = DateTime.now().toUtc();
    final amount = unitPrice * quantity;
    final businessDate = formatIsoDate(DateTime.now());

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
              businessDate: businessDate,
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
          'business_date': businessDate,
          'posted_by': postedBy,
        },
      );
    });
  }

  /// Enregistre un encaissement (F1.4 : especes, carte, virement, Mobile
  /// Money).
  Future<void> addPayment({
    required String folioId,
    required PaymentMethod method,
    required int amount,
    String? reference,
    String? receivedBy,
  }) async {
    final id = newId();
    final now = DateTime.now().toUtc();
    final businessDate = formatIsoDate(DateTime.now());

    await db.transaction(() async {
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

  /// Clot l'ardoise.
  ///
  /// Refuse tant que le solde n'est pas nul : une ardoise close avec un
  /// impaye est une creance que plus personne ne verra.
  Future<void> close(String folioId, {String? by}) async {
    final folio = await (db.select(db.folios)
          ..where((f) => f.id.equals(folioId)))
        .getSingle();

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
      await enqueue(
        table: 'folios',
        id: folioId,
        operation: SyncOp.UPDATE,
        payload: {'id': folioId, 'status': 'CLOSED'},
      );
    });
  }

  /// Recalcule charges, encaissements et solde depuis les lignes.
  ///
  /// En SQL et non en Dart : c'est SQLite qui fait la somme, donc le resultat
  /// ne depend pas de ce que l'application avait en memoire.
  Future<void> _recomputeTotals(String folioId) async {
    await db.customStatement(
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
      [Variable.withString(folioId)],
    );
  }
}
