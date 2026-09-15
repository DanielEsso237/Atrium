/// Comportement des cles etrangeres de la base locale.
///
/// Trois choses a prouver, parce que chacune peut silencieusement ne pas
/// fonctionner dans SQLite :
///
///   1. les contraintes sont bien actives (SQLite les ignore par defaut) ;
///   2. la suppression d'un parent emporte ses enfants, ce qui est ce qui
///      permettra de purger une periode entiere quand la fenetre glissante
///      avancera ;
///   3. dans une transaction de synchronisation, l'ordre d'arrivee des lignes
///      n'a pas d'importance -- sinon les contraintes seraient inutilisables
///      des le premier lot venu du serveur.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

const hotelId = '00000000-0000-7000-8000-000000000001';
const folioId = '00000000-0000-7000-8000-000000000010';
const itemId = '00000000-0000-7000-8000-000000000011';

void main() {
  late AtriumDatabase db;
  late DateTime now;

  setUp(() async {
    db = AtriumDatabase.memory();
    now = DateTime.now().toUtc();
    await db.customStatement('PRAGMA foreign_keys = ON');
  });
  tearDown(() async => db.close());

  Future<void> insertHotel() => db.into(db.hotels).insert(
        HotelsCompanion.insert(
          id: hotelId,
          createdAt: now,
          updatedAt: now,
          code: 'ATR',
          name: 'Hotel de test',
        ),
      );

  FoliosCompanion folio() => FoliosCompanion.insert(
        id: folioId,
        createdAt: now,
        updatedAt: now,
        hotelId: hotelId,
        number: 'F-0001',
      );

  FolioItemsCompanion folioItem() => FolioItemsCompanion.insert(
        id: itemId,
        createdAt: now,
        updatedAt: now,
        folioId: folioId,
        category: ChargeCategory.FNB,
        label: 'Cafe',
        businessDate: '2026-09-15',
        amount: const Value(500),
      );

  test('une charge sans folio est refusee', () async {
    await insertHotel();

    await expectLater(
      db.into(db.folioItems).insert(folioItem()),
      throwsA(isA<Exception>()),
    );
  });

  test('supprimer un folio emporte ses charges', () async {
    await insertHotel();
    await db.into(db.folios).insert(folio());
    await db.into(db.folioItems).insert(folioItem());

    expect(await db.select(db.folioItems).get(), hasLength(1));

    await (db.delete(db.folios)..where((f) => f.id.equals(folioId))).go();

    expect(await db.select(db.folioItems).get(), isEmpty);
  });

  test("dans un lot de synchronisation, l'ordre d'arrivee est libre", () async {
    await insertHotel();

    // L'enfant arrive avant son parent : accepte, parce que le controle est
    // reporte au commit et que le lot est coherent une fois complet.
    await db.syncTransaction(() async {
      await db.into(db.folioItems).insert(folioItem());
      await db.into(db.folios).insert(folio());
    });

    expect(await db.select(db.folioItems).get(), hasLength(1));
  });

  test('un lot incoherent est rejete en bloc', () async {
    await insertHotel();

    // Meme lot, mais le parent n'arrive jamais : tout doit etre annule.
    await expectLater(
      db.syncTransaction(() async {
        await db.into(db.folioItems).insert(folioItem());
      }),
      throwsA(isA<Exception>()),
    );

    expect(await db.select(db.folioItems).get(), isEmpty);
  });
}
