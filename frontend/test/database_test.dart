/// Verification du schema local.
///
/// Ce test ne valide pas du metier : il verifie que le schema Drift produit une
/// base SQLite reellement creable. C'est le seul moyen d'attraper tot une
/// table mal declaree, un index portant sur une colonne inexistante ou un
/// defaut invalide -- des erreurs qui, sinon, n'apparaitraient qu'au premier
/// lancement sur une tablette.
library;

import 'package:atrium/data/local/database.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;

  setUp(() => db = AtriumDatabase.memory());
  tearDown(() async => db.close());

  test('le schema cree toutes ses tables', () async {
    // Force l'ouverture effective de la base et l'execution des migrations.
    await db.customSelect('SELECT 1').get();

    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        )
        .get();
    final tables = rows.map((r) => r.read<String>('name')).toList();

    expect(tables.length, db.allTables.length);
    expect(tables, contains('rooms'));
    expect(tables, contains('folio_items'));
    expect(tables, contains('print_jobs'));
    expect(tables, contains('outbox_entries'));
  });

  test('les index metier sont poses', () async {
    await db.customSelect('SELECT 1').get();

    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name LIKE 'ix_%' OR name LIKE 'ux_%'",
        )
        .get();
    final indexes = rows.map((r) => r.read<String>('name')).toSet();

    expect(indexes, contains('ix_rooms_occupancy'));
    expect(indexes, contains('ix_order_items_station'));
    expect(indexes, contains('ux_stay_nights'));
  });

  test('les montants sont des entiers, sans echelle', () async {
    final hotelId = '00000000-0000-7000-8000-000000000001';
    final now = DateTime.now().toUtc();

    await db.into(db.hotels).insert(
          HotelsCompanion.insert(
            id: hotelId,
            createdAt: now,
            updatedAt: now,
            code: 'ATR',
            name: 'Hotel de test',
          ),
        );

    final hotel = await db.select(db.hotels).getSingle();
    expect(hotel.currency, 'XOF');

    // Un cafe a 500 FCFA se stocke 500. Pas 50000, pas 500.000.
    await db.into(db.roomTypes).insert(
          RoomTypesCompanion.insert(
            id: '00000000-0000-7000-8000-000000000002',
            createdAt: now,
            updatedAt: now,
            hotelId: hotelId,
            code: 'STD',
            label: 'Standard',
            defaultRate: const Value(25000),
          ),
        );

    final type = await db.select(db.roomTypes).getSingle();
    expect(type.defaultRate, 25000);
  });
}
