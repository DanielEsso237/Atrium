/// Les dernieres ventes d'un point de vente, sous ses tuiles (15 octobre).
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/historique_pdv_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/outlet_tab_repository.dart';
// Importe pour verifier que le bloc compile avec le reste.
import 'package:atrium/features/orders/historique_du_jour.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late OutletRow bar;
  late OutletRow cafe;
  final jour = businessDayFor(DateTime.now());

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    final points = OutletRepository(db);
    bar = await points.create(code: 'BAR', label: 'Bar');
    cafe = await points.create(code: 'CAFE', label: 'Café');
    await CashRepository(
      db,
    ).open(userId: utilisateurDemo, openingFloat: 0, outletId: bar.id);
  });

  tearDown(() => db.close());

  test('le bloc se construit', () {
    expect(HistoriqueDuJour(outlet: bar), isA<HistoriqueDuJour>());
  });

  test('une vente payee et une ardoise ouverte, la plus recente d abord, '
      'sans les ventes d un autre comptoir', () async {
    await OrderRepository(db).sellWalkIn(
      outlet: bar,
      lines: const [('Bière', 1500, 2, null), ('Jus', 1000, 1, null)],
      method: PaymentMethod.CASH,
      by: utilisateurDemo,
    );
    final ardoises = OutletTabRepository(db);
    final id = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
    await ardoises.renommer(ardoiseId: id, nom: 'Table 4');
    await ardoises.servir(
      pointDeVente: bar,
      ardoiseId: id,
      libelle: 'Castel',
      prixUnitaire: 1200,
      by: utilisateurDemo,
      categorie: ChargeCategory.FNB,
    );

    final ventes = await db
        .watchDernieresVentesPdv(pointDeVente: bar.id, jour: jour)
        .first;

    expect(ventes, hasLength(2));
    expect(ventes.first.titre, 'Table 4');
    expect(ventes.first.etat, EtatVentePdv.aPayer);
    expect(ventes.first.montant, 1200);
    expect(ventes.last.etat, EtatVentePdv.payee);
    expect(ventes.last.montant, 4000);
    expect(ventes.last.articles, '2 × Bière, Jus');
    expect(ventes.last.quantite, 3);

    expect(
      await db.watchDernieresVentesPdv(pointDeVente: cafe.id, jour: jour).first,
      isEmpty,
    );
  });
}
