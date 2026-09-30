/// Un plafond fixe depuis l'administration bloque bien une consommation.
///
/// Vecu en ecrivant l'ecran des plafonds : le check-in de la tablette ouvrait
/// l'ardoise sans son client, et la verification du seuil, qui le cherchait
/// par `folios.guest_id`, ne trouvait aucun plafond. La tablette laissait
/// passer, le serveur refusait (409), et la file se bloquait.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late GuestRepository guests;
  late ReservationRepository reservations;
  late FolioRepository folios;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    guests = GuestRepository(db);
    reservations = ReservationRepository(db);
    folios = FolioRepository(db);
  });

  tearDown(() => db.close());

  /// Un client arrive par un check-in fait ici ; renvoie client et ardoise.
  Future<(String, String)> arrivee() async {
    final client = await guests.create(firstName: 'Awa', lastName: 'Diallo');
    final chambre = await db
        .customSelect("SELECT id FROM rooms WHERE number = '101'")
        .getSingle();
    final resId = await reservations.create(
      guestId: client.id,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 2),
      nightlyRate: 25000,
      roomId: chambre.read<String>('id'),
    );
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(resId))).getSingle();
    await reservations.checkIn(lineId: ligne.id);
    return (client.id, (await folios.openFolioForStay(ligne.id))!.id);
  }

  test('le check-in pose le client de l\'ardoise', () async {
    final (client, ardoise) = await arrivee();

    final f = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(ardoise))).getSingle();
    expect(f.guestId, client);
  });

  test('un plafond fixe depuis l\'administration bloque une consommation',
      () async {
    final (client, ardoise) = await arrivee();
    // La nuitee : 25 000 sur l'ardoise. Plafond a 30 000.
    await guests.setCreditLimit(id: client, creditLimit: 30000);

    await folios.addCharge(
      folioId: ardoise,
      category: ChargeCategory.FNB,
      label: 'Diner',
      unitPrice: 5000,
    );
    await expectLater(
      folios.addCharge(
        folioId: ardoise,
        category: ChargeCategory.FNB,
        label: 'Biere',
        unitPrice: 1000,
      ),
      throwsStateError,
    );
  });

  test('une ardoise deja ouverte sans son client est controlee aussi',
      () async {
    final (client, ardoise) = await arrivee();
    // Le cas des ardoises ouvertes avant cette correction.
    await (db.update(db.folios)..where((f) => f.id.equals(ardoise))).write(
      const FoliosCompanion(guestId: Value(null)),
    );
    await guests.setCreditLimit(id: client, creditLimit: 25000);

    await expectLater(
      folios.addCharge(
        folioId: ardoise,
        category: ChargeCategory.FNB,
        label: 'Biere',
        unitPrice: 1000,
      ),
      throwsStateError,
    );
  });
}
