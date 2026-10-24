/// La tuile du chiffre d'affaires du jour, sur l'ecran Aujourd'hui (essai du
/// 24 octobre) : elle disait « encaissé » en affichant ce qui est vendu, et
/// comptait les lignes annulees et les arrhes, que les Rapports ecartent.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/dashboard_queries.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _folio = '01920000-0000-7000-8000-0000000f0001';

void main() {
  late AtriumDatabase db;

  setUp(() => db = AtriumDatabase.memory());
  tearDown(() => db.close());

  test('le chiffre du jour ecarte les lignes annulees et les arrhes', () async {
    final t0 = DateTime.utc(2026, 3, 1);
    final jour = businessDateNow();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: _folio,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            number: 'FOL-1',
          ),
        );
    for (final (i, categorie, montant, annulee) in [
      (1, ChargeCategory.FNB, 35000, false),
      (2, ChargeCategory.FNB, 4800, false),
      (3, ChargeCategory.FNB, 20000, true),
      (4, ChargeCategory.DEPOSIT, 15000, false),
    ]) {
      await db
          .into(db.folioItems)
          .insert(
            FolioItemsCompanion.insert(
              id: '01920000-0000-7000-8000-0000000f010$i',
              createdAt: t0,
              updatedAt: t0,
              folioId: _folio,
              category: categorie,
              label: 'Ligne',
              unitPrice: Value(montant),
              amount: Value(montant),
              businessDate: jour,
              isVoid: Value(annulee),
            ),
          );
    }

    final chiffres = await db.watchDashboard().first;
    expect(chiffres.caDuJour, 39800);
  });
}
