/// Revenir en arriere, sur le code d'un responsable (demande du 16 octobre).
///
/// Mme Diallo, deux nuits a 25 000 en 101. Les refus du serveur
/// (`app/api/v1/annulations.py`) sont repris ici, avant la file : un refus
/// qui arriverait par la file la bloquerait. Et le code du responsable est
/// exige meme quand c'est l'administrateur qui est connecte.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/auth_api.dart';
import 'package:atrium/data/repositories/autorisation_repository.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

const _reception = '01920000-0000-7000-8000-000000050002';

/// Un serveur injoignable : la tablette verifie le code elle-meme.
class _HorsLigne implements AuthApi {
  @override
  Future<Map<String, dynamic>> authorize({
    required String employeeCode,
    required String secret,
    required String permission,
  }) async => throw const ApiException(ApiFailure.offline, 'hors ligne');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AtriumDatabase db;
  late ReservationRepository reservations;
  late FolioRepository folios;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    reservations = ReservationRepository(db);
    folios = FolioRepository(db);
  });

  tearDown(() => db.close());

  Future<(String, String)> arriver() async {
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    final chambre = await db
        .customSelect("SELECT id FROM rooms WHERE number = '101'")
        .getSingle();
    final id = await reservations.create(
      guestId: client.id,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 3),
      nightlyRate: 25000,
      roomId: chambre.read<String>('id'),
    );
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(id))).getSingle();
    await reservations.checkIn(lineId: ligne.id, by: _reception);
    return (id, ligne.id);
  }

  Future<RoomRow> chambre101() => (db.select(
    db.rooms,
  )..where((r) => r.number.equals('101'))).getSingle();

  test('le code du responsable est verifie, et son droit', () async {
    final autorisation = AutorisationRepository(db, _HorsLigne());

    final admin = await autorisation.verifier(code: 'admin01', secret: pinDemo);
    expect(admin.id, utilisateurDemo);

    await expectLater(
      autorisation.verifier(code: 'ADMIN01', secret: '0000'),
      throwsStateError,
    );
    // La reception n'autorise pas : elle doit aller chercher un responsable.
    await expectLater(
      autorisation.verifier(code: 'RECEP01', secret: pinDemo),
      throwsStateError,
    );
  });

  test("annuler l'arrivee rend la chambre et retire l'ardoise", () async {
    final (dossierId, ligneId) = await arriver();
    final ardoise = (await folios.openFolioForStay(ligneId))!;
    expect(ardoise.balance, 50000);

    await reservations.annulerArrivee(
      lineId: ligneId,
      approuvePar: utilisateurDemo,
      motif: 'Mauvais client',
    );

    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(ligneId))).getSingle();
    expect(ligne.status, ReservationStatus.CONFIRMED);
    expect(ligne.checkedInAt, isNull);
    final dossier = await (db.select(
      db.reservations,
    )..where((r) => r.id.equals(dossierId))).getSingle();
    expect(dossier.status, ReservationStatus.CONFIRMED);
    expect((await chambre101()).occupancyStatus, OccupancyStatus.VACANT);
    expect(await folios.openFolioForStay(ligneId), isNull);

    final envoi = (await db.select(db.outboxEntries).get()).last;
    expect(envoi.entityTable, 'reservation_rooms');
    expect(jsonDecode(envoi.payload), {
      'id': ligneId,
      'action': 'UNDO_CHECK_IN',
      'approved_by': utilisateurDemo,
      'reason': 'Mauvais client',
    });

    // Une nouvelle arrivee ouvre une ardoise neuve, avec ses nuits.
    await reservations.checkIn(lineId: ligneId, by: _reception);
    expect((await folios.openFolioForStay(ligneId))!.balance, 50000);
  });

  test('une arrivee encaissee ne se defait qu\'apres l\'encaissement', () async {
    final (_, ligneId) = await arriver();
    await CashRepository(db).open(userId: _reception, openingFloat: 0);
    final ardoise = (await folios.openFolioForStay(ligneId))!;
    await folios.addPayment(
      folioId: ardoise.id,
      method: PaymentMethod.CASH,
      amount: 20000,
      receivedBy: _reception,
    );

    await expectLater(
      reservations.annulerArrivee(
        lineId: ligneId,
        approuvePar: utilisateurDemo,
        motif: 'Erreur',
      ),
      throwsStateError,
    );

    final paiement = (await db.select(db.payments).get()).single;
    await folios.annulerEncaissement(
      paymentId: paiement.id,
      approuvePar: utilisateurDemo,
      motif: 'Saisi deux fois',
      by: _reception,
    );
    // Le remboursement rend le du a l'ardoise, et sort du tiroir.
    expect((await folios.openFolioForStay(ligneId))!.balance, 50000);
    final remboursement = await (db.select(
      db.payments,
    )..where((p) => p.isRefund.equals(true))).getSingle();
    expect(remboursement.reversesPaymentId, paiement.id);
    expect(remboursement.cashSessionId, isNotNull);
    final envoi = jsonDecode((await db.select(db.outboxEntries).get()).last.payload);
    expect(envoi['action'], 'REVERSE');
    expect(envoi['reverses_payment_id'], paiement.id);

    // Une seule fois.
    await expectLater(
      folios.annulerEncaissement(
        paymentId: paiement.id,
        approuvePar: utilisateurDemo,
        motif: 'Encore',
        by: _reception,
      ),
      throwsStateError,
    );

    await reservations.annulerArrivee(
      lineId: ligneId,
      approuvePar: utilisateurDemo,
      motif: 'Erreur',
    );
    expect((await chambre101()).occupancyStatus, OccupancyStatus.VACANT);
  });

  test('annuler un depart remet le client dans sa chambre', () async {
    final (_, ligneId) = await arriver();
    await reservations.checkOut(lineId: ligneId, by: _reception);
    expect((await chambre101()).occupancyStatus, OccupancyStatus.VACANT);

    await reservations.annulerDepart(
      lineId: ligneId,
      approuvePar: utilisateurDemo,
      motif: 'Parti trop tot',
    );

    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.id.equals(ligneId))).getSingle();
    expect(ligne.status, ReservationStatus.CHECKED_IN);
    expect(ligne.checkedOutAt, isNull);
    expect((await chambre101()).occupancyStatus, OccupancyStatus.OCCUPIED);
    await expectLater(
      reservations.annulerDepart(
        lineId: ligneId,
        approuvePar: utilisateurDemo,
        motif: 'Encore',
      ),
      throwsStateError,
    );
  });
}
