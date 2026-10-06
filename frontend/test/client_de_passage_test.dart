/// Le client de passage, au comptoir.
///
/// Il boit deux bieres et mange des brochettes au bar, paie 6 000 et s'en
/// va : une ardoise WALK_IN close, payee dans la caisse de l'agent, et une
/// seule entree de file. Sans caisse ouverte, la vente est refusee avant
/// d'ecrire.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late OrderRepository commandes;
  late OutletRow bar;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    commandes = OrderRepository(db);
    bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
  });

  tearDown(() => db.close());

  const lignes = [('Bière', 1500, 2), ('Brochettes', 3000, 1)];

  test('vendue, payee et close, une seule entree de file', () async {
    final caisse = await CashRepository(
      db,
    ).open(userId: utilisateurDemo, openingFloat: 0);
    final avant = (await db.select(db.outboxEntries).get()).length;

    final id = await commandes.sellWalkIn(
      outlet: bar,
      lines: lignes,
      method: PaymentMethod.CASH,
      by: utilisateurDemo,
    );

    final folio = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(id))).getSingle();
    expect(folio.type, FolioType.WALK_IN);
    expect(folio.status, FolioStatus.CLOSED);
    expect(folio.chargesTotal, 6000);
    expect(folio.balance, 0);
    final paiement = await (db.select(
      db.payments,
    )..where((p) => p.folioId.equals(id))).getSingle();
    expect(paiement.amount, 6000);
    expect(paiement.cashSessionId, caisse);

    final file = await db.select(db.outboxEntries).get();
    expect(file.length - avant, 1);
    final p = jsonDecode(file.last.payload) as Map;
    expect(p['action'], 'WALK_IN');
    expect((p['items'] as List).length, 2);
    expect((p['payment'] as Map)['amount'], 6000);
  });

  test('sans caisse ouverte, rien n\'est vendu', () async {
    final avant = (await db.select(db.outboxEntries).get()).length;
    await expectLater(
      commandes.sellWalkIn(
        outlet: bar,
        lines: lignes,
        method: PaymentMethod.CASH,
        by: utilisateurDemo,
      ),
      throwsStateError,
    );
    expect((await db.select(db.outboxEntries).get()).length, avant);
    expect(
      await (db.select(
        db.folios,
      )..where((f) => f.type.equalsValue(FolioType.WALK_IN))).get(),
      isEmpty,
    );
  });
}
