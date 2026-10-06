/// Annuler une reservation, depuis la tablette.
///
/// Mme Diallo reserve la 101 et verse 15 000 d'arrhes, puis annule : le
/// dossier part, la chambre se libere, et les arrhes restent a l'hotel sur
/// une ardoise d'indemnite close. Un client deja arrive, lui, ne s'annule pas.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late ReservationRepository reservations;
  late String chambreId;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    reservations = ReservationRepository(db);
    chambreId = (await db
            .customSelect("SELECT id FROM rooms WHERE number = '101'")
            .getSingle())
        .read<String>('id');
  });

  tearDown(() => db.close());

  Future<String> reserver({int? arrhes}) async {
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    return reservations.create(
      guestId: client.id,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 3),
      nightlyRate: 25000,
      roomId: chambreId,
      depositCollected: arrhes,
      depositMethod: arrhes == null ? null : PaymentMethod.CASH,
    );
  }

  Future<RoomRow> chambre() =>
      (db.select(db.rooms)..where((r) => r.id.equals(chambreId))).getSingle();

  test('annulee : dossier, ligne et chambre liberes, envoi a part', () async {
    final id = await reserver();
    expect((await chambre()).occupancyStatus, OccupancyStatus.RESERVED);

    await reservations.cancel(reservationId: id, reason: ' Vol annulé ');

    final r = await (db.select(
      db.reservations,
    )..where((r) => r.id.equals(id))).getSingle();
    expect(r.status, ReservationStatus.CANCELLED);
    expect(r.cancelReason, 'Vol annulé');
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((l) => l.reservationId.equals(id))).getSingle();
    expect(ligne.status, ReservationStatus.CANCELLED);
    expect((await chambre()).occupancyStatus, OccupancyStatus.VACANT);

    final envoi = (await db.select(db.outboxEntries).get()).last;
    final p = jsonDecode(envoi.payload) as Map;
    expect(envoi.entityTable, 'reservations');
    expect(p['action'], 'CANCEL');
    expect(p['reason'], 'Vol annulé');
    expect(p['folio_id'], isNull);
  });

  test('les arrhes restent acquises sur une ardoise close', () async {
    final id = await reserver(arrhes: 15000);
    expect(await reservations.keptDeposit(id), 15000);

    await reservations.cancel(reservationId: id);

    final p =
        jsonDecode((await db.select(db.outboxEntries).get()).last.payload)
            as Map;
    final folio = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(p['folio_id'] as String))).getSingle();
    expect(folio.status, FolioStatus.CLOSED);
    expect(folio.chargesTotal, 15000);
    expect(folio.balance, 0);
    final paiement = await db.select(db.payments).getSingle();
    expect(paiement.folioId, folio.id);
    expect(await reservations.keptDeposit(id), isNull);
  });

  test('un client arrive ne s\'annule pas, rien n\'est ecrit', () async {
    final id = await reserver();
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((l) => l.reservationId.equals(id))).getSingle();
    await reservations.checkIn(lineId: ligne.id);
    final avant = (await db.select(db.outboxEntries).get()).length;

    await expectLater(
      reservations.cancel(reservationId: id),
      throwsStateError,
    );
    expect((await db.select(db.outboxEntries).get()).length, avant);
  });
}
