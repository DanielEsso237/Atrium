/// Reproduction du blocage constate a l'usage : « Porter a l'ardoise » reste
/// gris et rien ne se passe.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late FolioRepository repo;
  const folioId = '01920000-0000-7000-8000-000000009001';

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
}
