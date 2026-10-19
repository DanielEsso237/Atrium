/// Le tableau de bord et l'historique des stocks (18 octobre).
///
/// Ce qui compte : les memes etats que l'ecran Stocks (negatif, rupture,
/// bas), magasin par magasin ; le plus urgent d'abord ; un transfert vu de
/// ses deux magasins ; des entrees et sorties jour par jour.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/stock_tableau_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/stock_repository.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/stock/historique_stock_screen.dart';
import 'package:atrium/features/stock/stock_dashboard_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late UserRow admin;
  late UserRow recep;
  late String economat;
  late String bar;
  late String biere;
  late String savon;

  Future<String> magasin(String code, String label, {bool central = false}) async {
    final id = newId();
    final now = DateTime.now().toUtc();
    await db.into(db.stockLocations).insert(
      StockLocationsCompanion.insert(
        id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
        code: code, label: label, isCentral: Value(central),
      ),
    );
    return id;
  }

  Future<String> produit(String ref, String label, int prix, int seuil) async {
    final id = newId();
    final now = DateTime.now().toUtc();
    await db.into(db.products).insert(
      ProductsCompanion.insert(
        id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
        reference: ref, label: label,
        purchasePrice: Value(prix), minStock: Value(seuil),
      ),
    );
    return id;
  }

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    Future<UserRow> agent(String code) => (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals(code))).getSingle();
    admin = await agent('ADMIN01');
    recep = await agent('RECEP01');
    economat = await magasin('ECO_T', 'Économat test', central: true);
    bar = await magasin('BAR_T', 'Bar test');
    biere = await produit('BIE_T', 'Bière test', 600, 24);
    savon = await produit('SAV_T', 'Savon test', 150, 10);
    await produit('VIN_T', 'Vin test', 4500, 0);

    final depot = StockRepository(db);
    // L'economat : 30 bieres (au-dessus du seuil de 24), 4 savons (sous 10),
    // pas de vin (rupture : l'economat compte tous les produits).
    await depot.receive(
      placeId: economat, productId: biere, quantity: 30, unitCost: 600,
      by: admin.id,
    );
    await depot.receive(
      placeId: economat, productId: savon, quantity: 4, unitCost: 150,
      by: admin.id,
    );
    // Le bar demande 12 bieres, la direction valide ; puis il en perd 14 :
    // sous zero.
    final transfert = await depot.requestTransfer(
      fromPlaceId: economat, toPlaceId: bar, productId: biere, quantity: 12,
      by: recep.id,
    );
    await depot.approve(transfert, by: admin.id);
    await depot.sortir(
      placeId: bar, productId: biere, quantity: 14, perte: true,
      reason: 'Casse', by: recep.id,
    );
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  test('chaque magasin compte ses etats comme l ecran Stocks', () async {
    final etats = await db.watchEtatsMagasins([economat, bar]).first;
    expect(etats.first.id, economat, reason: "l'economat d'abord");
    final eco = etats.first;
    // Bieres 18 (sous 24) et savons 4 (sous 10) : bas ; vin : rupture --
    // plus les produits du jeu de demonstration, tous en rupture ici.
    expect(eco.bas, 2);
    expect(eco.negatif, 0);
    expect(eco.rupture, eco.produits - 2);
    expect(eco.valeur, 18 * 600 + 4 * 150);
    final b = etats.last;
    expect(b.produits, 1, reason: 'le bar ne compte que ce qu il a eu');
    expect(b.negatif, 1);
    expect(b.valeur, 0);
  });

  test('le plus urgent d abord : negatif, rupture, puis sous le seuil', () async {
    final alertes = await db.watchAlertesStock([economat, bar]).first;
    expect(alertes.first.produit, 'Bière test');
    expect(alertes.first.magasinId, bar);
    expect(alertes.first.etat, EtatProduit.negatif);
    expect(alertes.last.etat, EtatProduit.bas);
    expect(alertes.where((a) => a.produit == 'Vin test').single.etat,
        EtatProduit.rupture);
  });

  test('un transfert se lit de ses deux magasins, avec qui l a valide',
      () async {
    final duBar = await db.watchMouvementsStock([bar]).first;
    final t = duBar.firstWhere((m) => m.type == StockMovementType.TRANSFER);
    expect(t.contrepartieId, bar);
    expect(t.statut, StockMovementStatus.APPROVED);
    expect(t.agent, '${recep.firstName} ${recep.lastName}'.trim());
    expect(t.decidePar, '${admin.firstName} ${admin.lastName}'.trim());
    expect(duBar.map((m) => m.type), contains(StockMovementType.LOSS));
    expect(
      duBar.map((m) => m.type),
      isNot(contains(StockMovementType.IN)),
      reason: "les entrees de l'economat ne touchent pas le bar",
    );
  });

  test('entrees et sorties du jour, vues du bar', () async {
    final aujourdhui = DateTime.now();
    final (entrees, sorties) = await db
        .watchFluxStock(
          [bar],
          du: aujourdhui.subtract(const Duration(days: 6)),
          au: aujourdhui,
        )
        .first;
    expect(entrees, hasLength(7));
    expect(entrees.last, 12, reason: 'le transfert valide entre au bar');
    expect(sorties.last, 14, reason: 'la perte en sort');
  });

  for (final taille in [const Size(1280, 900), const Size(390, 844)]) {
    for (final (nom, ecran) in [
      ('tableau de bord', const StockDashboardScreen()),
      ('historique', const HistoriqueStockScreen()),
    ]) {
      testWidgets('le $nom des stocks s affiche sans debordement : $taille',
          (tester) async {
        tester.view.physicalSize = taille;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final acces =
            (await tester.runAsync(() => accessProfileFor(db, admin.id)))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              sessionProvider.overrideWith(
                () => _TestSession(SessionState(agent: admin, acces: acces)),
              ),
              pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
            ],
            child: MaterialApp(theme: themeAtrium(), home: ecran),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // Sur telephone, les lignes sont plus bas que l'ecran : la liste ne
        // les construit pas encore.
        if (taille.width > 600) {
          // Le tableau de bord ouvre sur ses colonnes par magasin ;
          // l'historique, sur ses lignes.
          expect(
            nom == 'historique'
                ? find.textContaining('Bière test')
                : find.text('État des stocks par magasin'),
            findsWidgets,
          );
        }

        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.runAsync(db.close);
      });
    }
  }
}
