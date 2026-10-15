/// Les factures des points de vente (ticket D2, 14 octobre).
///
/// Une facture du comptoir : un encaissement tombe dans le tiroir d'un point
/// de vente, avec ce qui y a ete servi. Le total du jour reste cache tant
/// qu'un tiroir est ouvert (comptage a l'aveugle).
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/factures_pdv_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/outlet_tab_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late OutletRow bar;
  late OutletRow resto;
  late String caisseBar;
  final aujourdhui = businessDayFor(DateTime.now());

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    final points = OutletRepository(db);
    bar = await points.create(code: 'BAR', label: 'Bar');
    resto = await points.create(code: 'CAFE', label: 'Café');
    final caisses = CashRepository(db);
    caisseBar = await caisses.open(
      userId: utilisateurDemo,
      openingFloat: 0,
      outletId: bar.id,
    );
    await caisses.open(
      userId: utilisateurDemo,
      openingFloat: 0,
      outletId: resto.id,
    );
  });

  tearDown(() => db.close());

  Future<List<FacturePdv>> factures(List<String> points) =>
      db.watchFacturesPdv(pointsDeVente: points, jour: aujourdhui).first;

  test('une vente payee tout de suite : une facture, ses lignes, son moyen',
      () async {
    await OrderRepository(db).sellWalkIn(
      outlet: bar,
      lines: const [('Bière', 1500, 2, null), ('Brochettes', 3000, 1, null)],
      method: PaymentMethod.MOBILE_MONEY,
      by: utilisateurDemo,
    );

    final f = (await factures([bar.id])).single;
    expect(f.pointDeVente, 'Bar');
    expect(f.montant, 6000);
    expect(f.moyen, PaymentMethod.MOBILE_MONEY);
    expect(f.lignes, [('Bière', 1500, 2), ('Brochettes', 3000, 1)]);
    expect(f.numero, startsWith('FOL'));
    expect(f.agent, isNotNull);
  });

  test('une ardoise nommee, payee a la fin : le nom sert de client',
      () async {
    final ardoises = OutletTabRepository(db);
    final id = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
    await ardoises.renommer(ardoiseId: id, nom: 'Table 4');
    await ardoises.servir(
      pointDeVente: bar,
      ardoiseId: id,
      libelle: 'Jus',
      prixUnitaire: 1000,
      by: utilisateurDemo,
      categorie: ChargeCategory.FNB,
    );
    await ardoises.payer(
      pointDeVente: bar,
      ardoiseId: id,
      moyen: PaymentMethod.CASH,
      by: utilisateurDemo,
    );

    final f = (await factures([bar.id])).single;
    expect(f.client, 'Table 4');
    expect(f.montant, 1000);
    expect(f.lignes.single.$1, 'Jus');
  });

  test('chaque comptoir ne voit que ses factures', () async {
    final commandes = OrderRepository(db);
    await commandes.sellWalkIn(
      outlet: bar,
      lines: const [('Bière', 1500, 1, null)],
      method: PaymentMethod.CASH,
      by: utilisateurDemo,
    );
    await commandes.sellWalkIn(
      outlet: resto,
      lines: const [('Café', 800, 1, null)],
      method: PaymentMethod.CASH,
      by: utilisateurDemo,
    );

    expect((await factures([bar.id])).map((f) => f.pointDeVente), ['Bar']);
    expect((await factures([resto.id])).map((f) => f.pointDeVente), ['Café']);
    expect(await factures([bar.id, resto.id]), hasLength(2));
    // Un autre jour : rien.
    final hier = DateTime(aujourdhui.year, aujourdhui.month, aujourdhui.day - 1);
    expect(
      await db
          .watchFacturesPdv(pointsDeVente: [bar.id], jour: hier)
          .first,
      isEmpty,
    );
  });

  test('le tiroir ouvert cache le total ; ferme, il se montre', () async {
    expect(await db.watchTiroirOuvertPdv([bar.id]).first, isTrue);
    await CashRepository(
      db,
    ).close(sessionId: caisseBar, countedAmount: 0, by: utilisateurDemo);
    expect(await db.watchTiroirOuvertPdv([bar.id]).first, isFalse);
    // Le cafe a encore son tiroir ouvert : ensemble, on reste a l'aveugle.
    expect(await db.watchTiroirOuvertPdv([bar.id, resto.id]).first, isTrue);
  });
}
