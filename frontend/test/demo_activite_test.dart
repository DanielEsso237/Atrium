/// L'activite de demonstration : visible partout, jamais envoyee au serveur,
/// toujours centree sur la journee en cours.
///
/// Le risque ici n'est pas qu'elle manque, c'est qu'elle fuie : un client
/// invente qui remonte au serveur y reste pour de bon, et un jeu qui se
/// decale sous les doigts d'un agent lui fait perdre ce qu'il venait de
/// saisir.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/queries/dashboard_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/demo_activite.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
  });

  tearDown(() => db.close());

  Future<int> compter(String sql) async =>
      (await db.customSelect(sql).getSingle()).read<int>('n');

  Future<List<String>> arrivees() async => [
    for (final l
        in await db
            .customSelect(
              'SELECT arrival_date FROM reservation_rooms ORDER BY arrival_date, id',
            )
            .get())
      l.read<String>('arrival_date'),
  ];

  test('le tableau de bord se remplit', () async {
    await seedDemoActivity(db);

    final resume = await db.watchDashboard().first;
    expect(resume.chambresOccupees, greaterThan(0));
    expect(resume.arriveesDuJour, greaterThan(0));
    expect(resume.departsDuJour, greaterThan(0));
    expect(resume.caDuJour, greaterThan(0));

    final historique = await db.watchHistorique(jours: 7).first;
    expect(historique.where((j) => j.occupees > 0).length, greaterThan(3));
    expect(await db.watchDernieresActivites().first, isNotEmpty);
    expect(await db.watchNotificationsNonLues().first, 2);
  });

  test('rien ne part vers le serveur', () async {
    await seedDemoActivity(db);

    expect(await compter('SELECT COUNT(*) AS n FROM outbox_entries'), 0);
    for (final table in const [
      'guests',
      'reservations',
      'reservation_rooms',
      'folios',
      'folio_items',
      'rooms',
      'housekeeping_tasks',
    ]) {
      expect(
        await compter(
          "SELECT COUNT(*) AS n FROM $table WHERE sync_state <> 'synced'",
        ),
        0,
        reason: table,
      );
    }
  });

  test('rejouer le meme jour ne duplique rien', () async {
    await seedDemoActivity(db);
    final avant = await compter('SELECT COUNT(*) AS n FROM reservations');

    await seedDemoActivity(db);
    expect(await compter('SELECT COUNT(*) AS n FROM reservations'), avant);
  });

  test('le jour suivant, tout le jeu avance d autant', () async {
    final maintenant = DateTime.now();
    await seedDemoActivity(db, maintenant: maintenant);
    final avant = await arrivees();

    await seedDemoActivity(
      db,
      maintenant: maintenant.add(const Duration(days: 2)),
    );
    final apres = await arrivees();

    expect(apres, [
      for (final a in avant)
        formatIso(DateTime.parse(a).add(const Duration(days: 2))),
    ]);
    // Les nuitees suivent, libelle et cle compris.
    expect(
      await compter('''
        SELECT COUNT(*) AS n FROM folio_items
        WHERE source_table = 'stay_nights'
          AND substr(source_id, 38) <> business_date
      '''),
      0,
    );
    expect(await compter('SELECT COUNT(*) AS n FROM outbox_entries'), 0);
  });

  test('un sejour modifie a la main n est plus deplace', () async {
    await seedDemoActivity(db);
    await db.customStatement(
      "UPDATE reservation_rooms SET sync_state = 'pending' "
      'WHERE id = (SELECT id FROM reservation_rooms LIMIT 1)',
    );
    final avant = await arrivees();

    await seedDemoActivity(
      db,
      maintenant: DateTime.now().add(const Duration(days: 1)),
    );
    expect(await arrivees(), avant);
  });

  test('seules les chambres liberees aujourd hui restent a nettoyer', () async {
    await seedDemoActivity(db);

    final resume = await db.watchDashboard().first;
    final departsDuJour = await compter('''
      SELECT COUNT(*) AS n FROM reservation_rooms
      WHERE status = 'CHECKED_OUT'
        AND departure_date = '${businessDateNow()}'
    ''');
    expect(resume.chambresANettoyer, departsDuJour);
  });
}

String formatIso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
