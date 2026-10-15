/// L'inventaire d'un magasin (demande du 15 octobre).
///
/// Ouvrir fige la quantite theorique ; compter calcule l'ecart ;
/// reequilibrer aligne le stock : un manque en perte, un surplus en
/// ajustement. Chaque geste part dans la file vers sa route.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/inventory_repository.dart';
import 'package:atrium/data/repositories/stock_repository.dart';
// Importe pour verifier que l'ecran compile avec le reste.
import 'package:atrium/features/stock/inventory_screen.dart';
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _agent = '00000000-0000-0000-0000-0000000000a1';

/// Un serveur de papier : il note les methodes, les chemins et les corps.
class _FauxApi extends ApiClient {
  _FauxApi() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final envois = <(String, String, Object?)>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    envois.add(('POST', path, body));
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    envois.add(('PUT', path, body));
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late StockRepository stocks;
  late InventoryRepository inventaires;
  late String bar;
  late String biere;
  late String jus;
  late String eau;

  setUp(() async {
    db = AtriumDatabase.memory();
    stocks = StockRepository(db);
    inventaires = InventoryRepository(db);
    final now = DateTime.now().toUtc();
    bar = newId();
    await db
        .into(db.stockLocations)
        .insert(
          StockLocationsCompanion.insert(
            id: bar, createdAt: now, updatedAt: now, hotelId: _hotel,
            code: 'BAR', label: 'Bar',
          ),
        );
    Future<String> produit(String ref, String libelle) async {
      final id = newId();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
              reference: ref, label: libelle,
            ),
          );
      return id;
    }

    biere = await produit('BIERE', 'Bière');
    jus = await produit('JUS', 'Jus');
    eau = await produit('EAU', 'Eau');
    await stocks.receive(placeId: bar, productId: biere, quantity: 24);
    await stocks.receive(placeId: bar, productId: jus, quantity: 10);
    await stocks.receive(placeId: bar, productId: eau, quantity: 6);
  });

  tearDown(() => db.close());

  Future<int> qte(String produit) async =>
      (await stocks.watchLines(bar).first)
          .firstWhere((l) => l.productId == produit)
          .quantity;

  test('l ecran se construit', () {
    expect(const InventoryScreen(), isA<InventoryScreen>());
  });

  test('ouvrir fige le theorique, une ligne par article en stock', () async {
    await inventaires.ouvrir(magasinId: bar, by: _agent);
    final inv = (await inventaires.watchOuvert(bar).first)!;
    expect(
      {for (final l in inv.lignes) l.libelle: l.theorique},
      {'Bière': 24, 'Eau': 6, 'Jus': 10},
    );
    expect(inv.comptees, 0);

    // Une livraison apres l'ouverture ne change pas la colonne theorique.
    await stocks.receive(placeId: bar, productId: biere, quantity: 6);
    final apres = (await inventaires.watchOuvert(bar).first)!;
    expect(apres.lignes.firstWhere((l) => l.productId == biere).theorique, 24);
  });

  test('un seul inventaire ouvert par magasin', () async {
    await inventaires.ouvrir(magasinId: bar, by: _agent);
    await expectLater(
      inventaires.ouvrir(magasinId: bar, by: _agent),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('déjà')),
      ),
    );
  });

  test('compter calcule l ecart ; une quantite negative est refusee',
      () async {
    final id = await inventaires.ouvrir(magasinId: bar, by: _agent);
    await inventaires.compter(inventaireId: id, productId: biere, quantite: 20);
    await inventaires.compter(inventaireId: id, productId: jus, quantite: 12);
    final inv = (await inventaires.watchOuvert(bar).first)!;
    expect(inv.lignes.firstWhere((l) => l.productId == biere).ecart, -4);
    expect(inv.lignes.firstWhere((l) => l.productId == jus).ecart, 2);
    expect(inv.lignes.firstWhere((l) => l.productId == eau).ecart, isNull);
    expect(inv.ecarts, hasLength(2));
    await expectLater(
      inventaires.compter(inventaireId: id, productId: eau, quantite: -1),
      throwsStateError,
    );
  });

  test('reequilibrer : manque en perte, surplus en ajustement, non compte '
      'intact, inventaire clos', () async {
    final id = await inventaires.ouvrir(magasinId: bar, by: _agent);
    await inventaires.compter(inventaireId: id, productId: biere, quantite: 20);
    await inventaires.compter(inventaireId: id, productId: jus, quantite: 12);

    final n = await inventaires.reequilibrer(inventaireId: id, by: _agent);

    expect(n, 2);
    expect(await qte(biere), 20);
    expect(await qte(jus), 12);
    expect(await qte(eau), 6);
    final mouvements = await (db.select(
      db.stockMovements,
    )..where((m) => m.reason.equals('Inventaire Bar'))).get();
    final parProduit = {for (final m in mouvements) m.productId: m};
    expect(parProduit[biere]!.type, StockMovementType.LOSS);
    expect(parProduit[biere]!.quantity, 4);
    expect(parProduit[jus]!.type, StockMovementType.ADJUSTMENT);
    expect(parProduit[jus]!.quantity, 2);
    expect(await inventaires.watchOuvert(bar).first, isNull);
    await expectLater(
      inventaires.compter(inventaireId: id, productId: eau, quantite: 6),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('clos')),
      ),
    );
  });

  test('rien de compte : on ne reequilibre pas', () async {
    final id = await inventaires.ouvrir(magasinId: bar, by: _agent);
    await expectLater(
      inventaires.reequilibrer(inventaireId: id, by: _agent),
      throwsStateError,
    );
  });

  test('abandonner : le stock ne bouge pas, on peut rouvrir', () async {
    final id = await inventaires.ouvrir(magasinId: bar, by: _agent);
    await inventaires.compter(inventaireId: id, productId: biere, quantite: 1);
    await inventaires.abandonner(id);
    expect(await qte(biere), 24);
    expect(await inventaires.watchOuvert(bar).first, isNull);
    await inventaires.ouvrir(magasinId: bar, by: _agent);
  });

  test("l'ecran suit l'inventaire : abandonne ou clos, il disparait", () async {
    // Un seul abonnement, comme l'ecran. Avant le 15 octobre, il restait
    // accroche au premier inventaire lu : abandonne, celui-ci restait
    // affiche, et chaque geste repondait « Inventaire introuvable ».
    final vus = <String?>[];
    final abonnement = inventaires
        .watchOuvert(bar)
        .listen((inv) => vus.add(inv?.id));
    Future<void> laisserPasser() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    final premier = await inventaires.ouvrir(magasinId: bar, by: _agent);
    await laisserPasser();
    expect(vus.last, premier);

    await inventaires.abandonner(premier);
    await laisserPasser();
    expect(vus.last, isNull);

    final second = await inventaires.ouvrir(magasinId: bar, by: _agent);
    await laisserPasser();
    expect(vus.last, second);
    await inventaires.compter(
      inventaireId: second,
      productId: biere,
      quantite: 20,
    );
    await inventaires.reequilibrer(inventaireId: second, by: _agent);
    await laisserPasser();
    expect(vus.last, isNull);

    await abonnement.cancel();
  });

  test('la file : ouvrir, compter, reequilibrer, vers les bonnes routes',
      () async {
    final id = await inventaires.ouvrir(magasinId: bar, by: _agent);
    await inventaires.compter(inventaireId: id, productId: biere, quantite: 20);
    await inventaires.reequilibrer(inventaireId: id, by: _agent);
    final mouvement = (await (db.select(
      db.stockMovements,
    )..where((m) => m.type.equalsValue(StockMovementType.LOSS))).getSingle());

    // Les entrees du stock du montage partent aussi : on ne regarde que
    // l'inventaire.
    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();
    final inv = api.envois.where((e) => e.$2.startsWith('/inventories'));

    expect(inv.map((e) => '${e.$1} ${e.$2}'), [
      'POST /inventories',
      'PUT /inventories/$id/lines/$biere',
      'POST /inventories/$id/rebalance',
    ]);
    final ouverture = inv.first.$3 as Map;
    expect(ouverture['stock_location_id'], bar);
    expect((ouverture['lines'] as List), hasLength(3));
    expect(inv.elementAt(1).$3, {'counted_qty': 20});
    expect(inv.last.$3, {
      'movement_ids': {biere: mouvement.id},
    });
    // Rien de l'inventaire ne reste dans la file.
    final reste = await db.select(db.outboxEntries).get();
    expect(
      reste.where(
        (e) =>
            e.entityTable == 'inventories' && e.status != OutboxStatus.ACKED,
      ),
      isEmpty,
    );
  });
}
