/// Une tablette de developpement repart neuve ; une tablette d'hotel n'est
/// pas touchee.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/purge_demo.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    // Un client et son ecriture en attente, comme le laissait l'ancien jeu.
    await GuestRepository(db).create(firstName: 'Rokia', lastName: 'Touré');
  });

  tearDown(() => db.close());

  Future<void> marquer() async {
    final now = DateTime.now().toUtc();
    await db
        .into(db.settings)
        .insert(
          SettingsCompanion.insert(
            id: '01920000-0000-7000-8000-000000009000',
            createdAt: now,
            updatedAt: now,
            hotelId: '01920000-0000-7000-8000-000000000001',
            key: 'demo.activite',
            scope: const Value(SettingScope.DEVICE),
          ),
        );
  }

  test('une tablette marquee repart neuve', () async {
    await marquer();

    expect(await purgeDemoActivity(db), isTrue);

    expect(await db.select(db.guests).get(), isEmpty);
    expect(await db.select(db.outboxEntries).get(), isEmpty);
    expect(await db.select(db.rooms).get(), isNotEmpty);
    final codes = (await db.select(db.users).get()).map((u) => u.employeeCode);
    expect(codes, containsAll(['ADMIN01', 'RECEP01', 'MENAGE01']));
    expect(codes, isNot(contains('RESTAU01')));
    // Une seule fois : la marque est partie.
    expect(await purgeDemoActivity(db), isFalse);
  });

  test('une tablette sans marque garde son activite', () async {
    expect(await purgeDemoActivity(db), isFalse);

    expect(await db.select(db.guests).get(), hasLength(1));
    expect(await db.select(db.outboxEntries).get(), isNotEmpty);
  });
}
