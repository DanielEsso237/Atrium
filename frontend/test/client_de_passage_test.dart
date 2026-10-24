/// Le client de passage, au comptoir.
///
/// Il boit deux bieres et mange des brochettes au bar, paie 6 000 et s'en
/// va : une ardoise WALK_IN close, payee dans la caisse de l'agent, et une
/// seule entree de file. Sans caisse ouverte, la vente est refusee avant
/// d'ecrire.
library;

import 'dart:convert';

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/historique_pdv_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
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

  const lignes = [('Bière', 1500, 2, null), ('Brochettes', 3000, 1, null)];

  test('vendue, payee et close, une seule entree de file', () async {
    // Le tiroir du bar : la recette du bar tombe dans le sien (un tiroir par
    // point de vente, migration 0020), pas dans la caisse centrale.
    final caisse = await CashRepository(
      db,
    ).open(userId: utilisateurDemo, openingFloat: 0, outletId: bar.id);
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

  // Essai du 24 octobre : Jean-Paul Mbarga, loge, paie sur place depuis sa
  // tuile, et la vente sortait en « Client divers ».
  test('un client loge qui paie sur place garde son nom', () async {
    await CashRepository(
      db,
    ).open(userId: utilisateurDemo, openingFloat: 0, outletId: bar.id);
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Jean-Paul', lastName: 'Mbarga');

    final id = await commandes.sellWalkIn(
      outlet: bar,
      lines: lignes,
      method: PaymentMethod.CASH,
      by: utilisateurDemo,
      guestId: client.id,
    );

    final folio = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(id))).getSingle();
    expect(folio.guestId, client.id);
    final p = jsonDecode((await db.select(db.outboxEntries).get()).last.payload)
        as Map;
    expect(p['guest_id'], client.id);
    final ventes = await db
        .watchDernieresVentesPdv(
          pointDeVente: bar.id,
          jour: businessDayFor(DateTime.now()),
        )
        .first;
    expect(ventes.single.titre, 'Jean-Paul Mbarga');
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
