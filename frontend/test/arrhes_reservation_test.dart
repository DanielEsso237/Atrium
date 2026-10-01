/// Les arrhes, de la reservation a l'ardoise.
///
/// Mme Diallo reserve deux nuits a 25 000 : 50 000. Regle a 30 % : 15 000
/// d'arrhes. Payees : l'ardoise, a l'arrivee, ne demande plus que 35 000.
/// Les deux refus du serveur sont faits ici : une ecriture d'arrhes ne doit
/// jamais bloquer la file.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/data/repositories/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late ReservationRepository reservations;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    reservations = ReservationRepository(db);
    await SettingsRepository(db).setDepositRule(const DepositRule.percent(3000));
  });

  tearDown(() => db.close());

  Future<String> reserver({int? arrhes, PaymentMethod? moyen}) async {
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    final chambre = await db
        .customSelect("SELECT id FROM rooms WHERE number = '101'")
        .getSingle();
    return reservations.create(
      guestId: client.id,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 3),
      nightlyRate: 25000,
      roomId: chambre.read<String>('id'),
      depositCollected: arrhes,
      depositMethod: moyen,
    );
  }

  Future<ReservationRow> dossier(String id) =>
      (db.select(db.reservations)..where((r) => r.id.equals(id))).getSingle();

  Future<Map> envoi(String id) async {
    final e = (await db.select(db.outboxEntries).get()).firstWhere(
      (e) => e.entityTable == 'reservations' && e.entityId == id,
    );
    return jsonDecode(e.payload) as Map;
  }

  test('arrhes encaissees : partent avec la reservation', () async {
    final id = await reserver(arrhes: 15000, moyen: PaymentMethod.MOBILE_MONEY);

    final r = await dossier(id);
    expect(r.depositAmount, 15000);
    expect(r.depositPaidAt, isNotNull);
    final p = await envoi(id);
    expect(p['deposit_amount'], 15000);
    expect(p['deposit_method'], 'MOBILE_MONEY');
  });

  test('payees plus tard : dues selon la regle, rien d\'envoye', () async {
    final id = await reserver();

    final r = await dossier(id);
    expect(r.depositAmount, 15000);
    expect(r.depositPaidAt, isNull);
    final p = await envoi(id);
    expect(p['deposit_amount'], isNull);
    expect(p['deposit_method'], isNull);
  });

  test('les refus du serveur sont faits avant d\'ecrire', () async {
    final avant = (await db.select(db.outboxEntries).get()).length;

    await expectLater(
      reserver(arrhes: 60000, moyen: PaymentMethod.CASH),
      throwsStateError,
    );
    await expectLater(reserver(arrhes: 15000), throwsStateError);

    // Le client cree pour chaque essai est la seule ecriture.
    final apres = await db.select(db.outboxEntries).get();
    expect(
      apres.where((e) => e.entityTable == 'reservations'),
      isEmpty,
    );
    expect(apres.length - avant, 2);
  });

  test('a l\'arrivee, l\'ardoise ne demande plus que le reste', () async {
    final id = await reserver(arrhes: 15000, moyen: PaymentMethod.CASH);
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(id))).getSingle();

    await reservations.checkIn(lineId: ligne.id);

    final ardoise = (await FolioRepository(db).openFolioForStay(ligne.id))!;
    expect(ardoise.chargesTotal, 50000);
    expect(ardoise.paymentsTotal, 15000);
    expect(ardoise.balance, 35000);
  });
}
