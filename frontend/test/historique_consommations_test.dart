/// L'historique d'un client dans un point de vente, vu depuis la saisie.
///
/// Ce sejour et les precedents (meme fiche client), dans ce point de vente
/// seulement ; une ligne annulee n'y figure pas.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
  });

  tearDown(() => db.close());

  test('ce sejour et les precedents, dans ce point de vente seulement',
      () async {
    final bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    final resto = await OutletRepository(
      db,
    ).create(code: 'RESTO2', label: 'Resto');
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    final now = DateTime.now().toUtc();

    Future<String> ardoise() async {
      final id = newId();
      await db
          .into(db.folios)
          .insert(
            FoliosCompanion.insert(
              id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
              number: 'FOL-${id.substring(0, 8)}', guestId: Value(client.id),
            ),
          );
      return id;
    }

    Future<void> ligne(
      String folio,
      String outlet,
      String label,
      String jour, {
      bool annulee = false,
    }) => db
        .into(db.folioItems)
        .insert(
          FolioItemsCompanion.insert(
            id: newId(), createdAt: now, updatedAt: now, folioId: folio,
            category: ChargeCategory.FNB, label: label, businessDate: jour,
            amount: const Value(1000), sourceTable: const Value('outlets'),
            sourceId: Value(outlet), isVoid: Value(annulee),
          ),
        );

    final ancien = await ardoise();
    final actuel = await ardoise();
    await ligne(ancien, bar.id, 'Mutzig', '2026-09-01');
    await ligne(actuel, bar.id, 'Guinness', '2026-10-08');
    await ligne(actuel, bar.id, 'Castel', '2026-10-08', annulee: true);
    await ligne(actuel, resto.id, 'Ndolé', '2026-10-08');

    final historique = await OrderRepository(
      db,
    ).watchGuestHistory(folioId: actuel, outletId: bar.id).first;
    expect(historique.map((c) => c.label), ['Guinness', 'Mutzig']);
  });
}
