/// Le jeu de donnees de test : il remplit les rapports, declenche les
/// alertes, passe par la file d'envoi, et ne se charge qu'une fois.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/queries/alert_queries.dart';
import 'package:atrium/data/local/queries/report_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/donnees_de_test.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    await OutletRepository(db).create(code: 'BAR', label: 'Bar');
  });

  tearDown(() => db.close());

  test('le complement remplit les rapports et declenche les alertes',
      () async {
    final admin = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();

    final bilan = await chargerDonneesDeTest(db, agentId: admin.id);
    expect(bilan, contains('Complément : '));
    expect(bilan, contains('7 ventes au comptoir'));

    final jour = businessDayFor(DateTime.now());
    final r = await db.chargerRapport(
      FiltresRapport(du: DateTime(jour.year, jour.month, jour.day - 7), au: jour),
    );
    expect(r.ventesPointsDeVente, greaterThan(0));
    expect(r.cles.encaisse, greaterThan(0));
    expect(r.ecartCaisse, -500);
    expect(r.gestion.ticketsSignales, 3);
    expect(r.gestion.ticketsResolus, 1);

    final alertes = await db.chargerAlertes(
      ContexteAlertes(
        agentId: admin.id,
        peut: (_) => true,
        maintenant: DateTime.now(),
      ),
    );
    expect(
      alertes.where((a) => a.niveau == NiveauAlerte.critique).map((a) => a.titre),
      contains("Panne urgente : Fuite d'eau dans la salle de bain"),
    );

    // Tout est parti dans la file : un serveur recevra ces saisies.
    final enAttente = await db.select(db.outboxEntries).get();
    expect(enAttente.length, greaterThan(20));

    // Une seconde fois : rien n'est recree.
    final encore = await chargerDonneesDeTest(db, agentId: admin.id);
    expect(encore, contains('déjà'));
    expect(await db.select(db.outboxEntries).get(), hasLength(enAttente.length));
  });
}
