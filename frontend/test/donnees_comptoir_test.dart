/// Les donnees de test du point de vente : un bar, un restaurant, et ce que
/// les clients installes y ont deja pris -- chargees une seule fois, et
/// toujours par la file d'envoi.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/donnees_de_test.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late String admin;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    admin = (await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle()).id;
  });

  tearDown(() => db.close());

  test('le bar et le restaurant, et l historique de chaque chambre', () async {
    final bilan = await chargerDonneesDeTest(
      db,
      agentId: admin,
      peut: (_) => true,
    );
    expect(bilan, contains('11 consommations au bar et au restaurant'));

    final points = await db.select(db.outlets).get();
    final bar = points.firstWhere((o) => o.label == 'Bar / Lounge');
    final chambres = await OrderRepository(db).watchChargeableRooms().first;
    final c102 = chambres.firstWhere((c) => c.roomNumber == '102');

    final historique = await OrderRepository(
      db,
    ).watchGuestHistory(folioId: c102.folioId, outletId: bar.id).first;
    expect(
      historique.map((h) => h.label),
      containsAll(['Mutzig', 'Guinness', 'Top Ananas']),
    );
    expect(
      await OrderRepository(
        db,
      ).watchStaySpendAt(folioId: c102.folioId, outletId: bar.id).first,
      2 * 1000 + 1200 + 600,
    );

    // Chaque ligne et chaque point de vente partent dans la file.
    final file = await db.select(db.outboxEntries).get();
    expect(file.where((e) => e.entityTable == 'outlets'), hasLength(2));

    // Une seconde fois : rien de plus.
    final avant = file.length;
    expect(
      await chargerDonneesDeTest(db, agentId: admin, peut: (_) => true),
      'Les données de test sont déjà sur cette tablette.',
    );
    expect(await db.select(db.outboxEntries).get(), hasLength(avant));
  });

  test('sans le droit de creer un point de vente, rien n est cree', () async {
    final bilan = await chargerDonneesDeTest(db, agentId: admin);
    expect(bilan, contains('Aucun point de vente'));
    expect(await db.select(db.outlets).get(), isEmpty);
  });
}
