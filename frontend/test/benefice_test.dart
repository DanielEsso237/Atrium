/// Le benefice : les depenses saisies sur la tablette, ce qu'elles envoient au
/// serveur, et le calcul qui les retranche des recettes avec les couts du
/// stock.
library;

import 'dart:convert';

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/report_queries.dart';
import 'package:atrium/data/repositories/expense_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _folio = '01920000-0000-7000-8000-0000000f0001';

void main() {
  late AtriumDatabase db;
  late ExpenseRepository depenses;

  setUp(() {
    db = AtriumDatabase.memory();
    depenses = ExpenseRepository(db);
  });
  tearDown(() => db.close());

  SaisieDepense saisie({
    String jour = '2026-03-10',
    int montant = 185000,
    String libelle = 'Facture ENEO',
    ExpenseCategory rubrique = ExpenseCategory.ELECTRICITY,
  }) => SaisieDepense(
    businessDate: jour,
    category: rubrique,
    label: libelle,
    amount: montant,
    method: PaymentMethod.TRANSFER,
  );

  Future<List<Map<String, Object?>>> file() async => [
    for (final e in await db.select(db.outboxEntries).get())
      jsonDecode(e.payload) as Map<String, Object?>,
  ];

  test('une depense part dans la file, une annulation aussi', () async {
    final id = await depenses.create(saisie(), by: 'agent');
    await depenses.annuler(id, motif: '  Saisie en double ', by: 'agent');
    // Deja annulee : rien de plus dans la file.
    await depenses.annuler(id, motif: 'Encore');

    final envois = await file();
    expect(envois, hasLength(2));
    expect(envois.first, containsPair('amount', 185000));
    expect(envois.first, containsPair('category', 'ELECTRICITY'));
    expect(envois.first, containsPair('supplier', null));
    expect(envois.last, {'id': id, 'action': 'VOID', 'reason': 'Saisie en double'});
    final ligne = await db.select(db.expenses).getSingle();
    expect(ligne.isVoid, isTrue);
    expect(
      () => depenses.update(id, saisie(montant: 1000)),
      throwsA(isA<StateError>()),
    );
  });

  test('les refus du serveur, avant la file', () async {
    final demain = businessDateNow(
      at: DateTime.now().add(const Duration(days: 2)),
    );
    for (final s in [
      saisie(montant: 0),
      saisie(montant: montantMaxDepense + 1),
      saisie(libelle: '   '),
      saisie(libelle: 'x' * 161),
      saisie(jour: demain),
    ]) {
      expect(() => depenses.create(s), throwsA(isA<StateError>()));
    }
    expect(await file(), isEmpty);
  });

  test('le benefice retranche les couts du stock et les depenses', () async {
    final t0 = DateTime.utc(2026, 3, 1);
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
    for (final (i, jour, categorie, montant) in [
      (1, '2026-03-10', ChargeCategory.ROOM, 300000),
      (2, '2026-03-11', ChargeCategory.FNB, 120000),
      // Un acompte n'est pas une vente.
      (3, '2026-03-11', ChargeCategory.DEPOSIT, 50000),
      // Hors de la periode.
      (4, '2026-03-20', ChargeCategory.FNB, 99000),
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
              sourceTable: const Value('outlets'),
              sourceId: const Value('bar'),
            ),
          );
    }
    for (final (jour, ventes, conso) in [
      ('2026-03-10', 30000, 12000),
      ('2026-03-11', 18000, 9000),
    ]) {
      await db
          .into(db.dailyCosts)
          .insert(
            DailyCostsCompanion.insert(
              businessDate: jour,
              costOfSales: Value(ventes),
              consumption: Value(conso),
              purchases: const Value(400000),
              updatedAt: t0,
            ),
          );
    }
    await depenses.create(saisie(jour: '2026-03-10'));
    await depenses.create(
      saisie(
        jour: '2026-03-11',
        montant: 150000,
        rubrique: ExpenseCategory.SALARIES,
      ),
    );
    final annulee = await depenses.create(saisie(jour: '2026-03-11'));
    await depenses.annuler(annulee, motif: 'Erreur');

    // Un filtre de point de vente ne change rien au benefice de l'hotel.
    final b = await db.benefice(
      FiltresRapport(
        du: DateTime(2026, 3, 10),
        au: DateTime(2026, 3, 11),
        pointDeVenteId: 'autre',
      ),
    );

    expect(b.recettes, 420000);
    expect(b.coutDesVentes, 48000);
    expect(b.consommations, 21000);
    expect(b.achats, 800000, reason: 'indicatif, jamais retranche');
    expect([for (final d in b.depenses) (d.cle, d.montant)], [
      ('ELECTRICITY', 185000),
      ('SALARIES', 150000),
    ]);
    expect(b.benefice, 420000 - 48000 - 21000 - 185000 - 150000);
    expect(b.coutsArretesAu, DateTime(2026, 3, 11));
  });
}
