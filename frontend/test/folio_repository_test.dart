/// Reproduction du blocage constate a l'usage : « Porter a l'ardoise » reste
/// gris et rien ne se passe.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late FolioRepository repo;
  const folioId = '01920000-0000-7000-8000-000000009001';
  const agent = '01920000-0000-7000-8000-000000050002';

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    repo = FolioRepository(db);

    final now = DateTime.now().toUtc();
    await db
        .into(db.guests)
        .insert(
          GuestsCompanion.insert(
            id: '01920000-0000-7000-8000-000000009301',
            createdAt: now,
            updatedAt: now,
            hotelId: '01920000-0000-7000-8000-000000000001',
            code: 'CLI-00001',
            firstName: 'Amadou',
            lastName: 'Kone',
          ),
        );
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: folioId,
            createdAt: now,
            updatedAt: now,
            hotelId: '01920000-0000-7000-8000-000000000001',
            number: 'FOL-000001',
            type: const Value(FolioType.GUEST),
            status: const Value(FolioStatus.OPEN),
          ),
        );
  });
  tearDown(() async => db.close());

  test('porter une charge revient et met a jour les totaux', () async {
    await repo
        .addCharge(
          folioId: folioId,
          category: ChargeCategory.FNB,
          label: 'Room service',
          unitPrice: 18500,
        )
        .timeout(const Duration(seconds: 5));

    final folio = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(folioId))).getSingle();
    expect(folio.chargesTotal, 18500);
    expect(folio.balance, 18500);

    final file = await db.select(db.outboxEntries).get();
    expect(file, hasLength(1), reason: 'l ecriture doit etre enfilee');
  });

  test('les nuitees se portent une par nuit, sans doublon', () async {
    const ligne = '01920000-0000-7000-8000-000000009101';
    final now = DateTime.now().toUtc();
    final chambre = (await db.select(db.rooms).get()).first;

    await db
        .into(db.reservations)
        .insert(
          ReservationsCompanion.insert(
            id: '01920000-0000-7000-8000-000000009201',
            createdAt: now,
            updatedAt: now,
            hotelId: '01920000-0000-7000-8000-000000000001',
            reference: 'RES-000001',
            guestId: '01920000-0000-7000-8000-000000009301',
            arrivalDate: '2026-09-20',
            departureDate: '2026-09-22',
          ),
        );
    await db
        .into(db.reservationRooms)
        .insert(
          ReservationRoomsCompanion.insert(
            id: ligne,
            createdAt: now,
            updatedAt: now,
            reservationId: '01920000-0000-7000-8000-000000009201',
            roomTypeId: chambre.roomTypeId,
            roomId: Value(chambre.id),
            // Sejour du 20 au 22 : deux nuits, la 20 et la 21. La nuit du
            // depart n'existe pas.
            arrivalDate: '2026-09-20',
            departureDate: '2026-09-22',
            nightlyRate: const Value(25000),
          ),
        );

    final posees = await repo.postStayNights(
      folioId: folioId,
      stayLineId: ligne,
    );
    expect(posees, 2, reason: 'deux nuits, pas trois');

    var folio = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(folioId))).getSingle();
    expect(folio.chargesTotal, 50000);

    // Rejouer ne doit rien ajouter : c'est ce qui permet de l'appeler a
    // chaque ouverture de l'ardoise sans y penser.
    final encore = await repo.postStayNights(
      folioId: folioId,
      stayLineId: ligne,
    );
    expect(encore, 0);

    folio = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(folioId))).getSingle();
    expect(folio.chargesTotal, 50000);
  });

  group('encaisser', () {
    Future<int> solde() async {
      final f = await (db.select(
        db.folios,
      )..where((f) => f.id.equals(folioId))).getSingle();
      return f.balance;
    }

    setUp(() async {
      await repo.addCharge(
        folioId: folioId,
        category: ChargeCategory.ROOM,
        label: 'Nuitee',
        unitPrice: 50000,
      );
      await CashRepository(db).open(userId: agent, openingFloat: 0);
    });

    test('sans caisse ouverte, rien n est encaisse ni envoye', () async {
      final caisse = (await CashRepository(db).openSessionId(agent))!;
      await CashRepository(db).close(sessionId: caisse, countedAmount: 0);
      final avant = (await db.select(db.outboxEntries).get()).length;

      await expectLater(
        repo.addPayment(
          folioId: folioId,
          method: PaymentMethod.CASH,
          amount: 50000,
          receivedBy: agent,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('Ouvrez votre caisse'),
          ),
        ),
      );
      expect(await solde(), 50000);
      expect(await db.select(db.outboxEntries).get(), hasLength(avant));
    });

    test('sans agent, l encaissement est refuse', () async {
      await expectLater(
        repo.addPayment(
          folioId: folioId,
          method: PaymentMethod.CASH,
          amount: 50000,
        ),
        throwsStateError,
      );
    });

    test('un encaissement complet solde l ardoise', () async {
      await repo.addPayment(
        folioId: folioId,
        method: PaymentMethod.CASH,
        receivedBy: agent,
        amount: 50000,
      );
      expect(await solde(), 0);
    });

    test('un encaissement sans reference passe', () async {
      // Le champ a quitte l'ecran : plus personne ne la remplit, meme pour un
      // Mobile Money ou on l'aurait attendue. L'encaissement doit passer et
      // remonter tel quel -- le serveur la tient pour facultative.
      await repo.addPayment(
        folioId: folioId,
        method: PaymentMethod.MOBILE_MONEY,
        receivedBy: agent,
        amount: 50000,
      );

      expect(await solde(), 0);
      final paiement = await db.select(db.payments).getSingle();
      expect(paiement.reference, isNull);
      final file = await (db.select(
        db.outboxEntries,
      )..where((e) => e.entityTable.equals('payments'))).get();
      expect(file, hasLength(1), reason: 'l encaissement doit remonter');
    });

    test('on ne peut pas encaisser deux fois la meme facture', () async {
      // Constate a l usage. Rien ne plantait : le solde passait simplement en
      // negatif, et l ecart ne se voyait qu a la caisse en fin de service,
      // sans moyen de savoir quel client avait trop paye.
      await repo.addPayment(
        folioId: folioId,
        method: PaymentMethod.CASH,
        receivedBy: agent,
        amount: 50000,
      );

      await expectLater(
        repo.addPayment(
          folioId: folioId,
          method: PaymentMethod.CASH,
          receivedBy: agent,
          amount: 50000,
        ),
        throwsA(isA<StateError>()),
      );

      expect(await solde(), 0, reason: 'le refus ne doit rien avoir ecrit');
    });

    test('on ne peut pas encaisser plus que le reste du', () async {
      // Un client qui tend 60 000 pour 50 000 fait enregistrer 50 000 : les
      // 10 000 rendus sont de la manipulation d especes.
      await expectLater(
        repo.addPayment(
          folioId: folioId,
          method: PaymentMethod.CASH,
          receivedBy: agent,
          amount: 60000,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await solde(), 50000);
    });

    test('deux encaissements partiels sont possibles', () async {
      // Le cas legitime : le client paie en deux fois, au comptoir.
      await repo.addPayment(
        folioId: folioId,
        method: PaymentMethod.CASH,
        receivedBy: agent,
        amount: 30000,
      );
      expect(await solde(), 20000);

      await repo.addPayment(
        folioId: folioId,
        method: PaymentMethod.MOBILE_MONEY,
        receivedBy: agent,
        amount: 20000,
      );
      expect(await solde(), 0);
    });

    test('un montant nul ou negatif est refuse', () async {
      await expectLater(
        repo.addPayment(
          folioId: folioId,
          method: PaymentMethod.CASH,
          receivedBy: agent,
          amount: 0,
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repo.addPayment(
          folioId: folioId,
          method: PaymentMethod.CASH,
          receivedBy: agent,
          amount: -5000,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await solde(), 50000);
    });

    test('une ardoise close n accepte plus rien', () async {
      await repo.addPayment(
        folioId: folioId,
        method: PaymentMethod.CASH,
        receivedBy: agent,
        amount: 50000,
      );
      await repo.close(folioId);

      await expectLater(
        repo.addPayment(
          folioId: folioId,
          method: PaymentMethod.CASH,
          receivedBy: agent,
          amount: 1000,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
