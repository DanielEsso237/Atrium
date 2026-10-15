/// La descente des inventaires (15 octobre).
///
/// Ce qui compte : un second poste reprend l'inventaire qu'un collegue a
/// ouvert -- avec la quantite theorique du serveur et ce qui a deja ete
/// compte --, apprend qu'il a ete abandonne ou clos, et n'ecrase jamais un
/// comptage fait ici et pas encore remonte.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/inventory_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

const _economat = '01920000-0000-7000-8000-00000000e001';
const _biere = '01920000-0000-7000-8000-00000000e004';
const _savon = '01920000-0000-7000-8000-00000000e006';
const _inventaire = '01920000-0000-7000-8000-00000000f001';
const _ligneBiere = '01920000-0000-7000-8000-00000000f002';
const _ligneSavon = '01920000-0000-7000-8000-00000000f003';
const _agent = '01920000-0000-7000-8000-000000050001';

const _magasins = [
  RemoteStockLocation(
    id: _economat, code: 'ECONOMAT', label: 'Économat', sortOrder: 0,
    isCentral: true,
  ),
];

const _produits = [
  RemoteProduct(
    id: _biere, reference: 'BIERE', label: 'Biere 65 cl', unit: 'U',
    purchasePrice: 600, salePrice: 1500, minStock: 6,
  ),
  RemoteProduct(
    id: _savon, reference: 'SAVON', label: 'Savon', unit: 'U',
    purchasePrice: 250, salePrice: 0, minStock: 0,
  ),
];

RemoteInventory _ouvert({int? biereComptee, DateTime? abandonne, String statut = 'COUNTING'}) =>
    RemoteInventory(
      id: _inventaire,
      stockLocationId: _economat,
      label: 'Inventaire Économat',
      status: statut,
      inventoryDate: '2026-10-15',
      startedAt: DateTime.utc(2026, 10, 15, 8),
      deletedAt: abandonne,
      lines: [
        RemoteInventoryLine(
          id: _ligneBiere,
          productId: _biere,
          theoreticalQty: 24,
          countedQty: biereComptee,
          variance: biereComptee == null ? 0 : biereComptee - 24,
        ),
        const RemoteInventoryLine(
          id: _ligneSavon, productId: _savon, theoreticalQty: 10, variance: 0,
        ),
      ],
    );

void main() {
  late AtriumDatabase db;
  late InventoryRepository inventaires;

  setUp(() {
    db = AtriumDatabase.memory();
    inventaires = InventoryRepository(db);
  });
  tearDown(() => db.close());

  Future<void> descendre(List<RemoteInventory>? inventories) async {
    final api = FakeCatalogApi(
      products: _produits,
      stockLocations: _magasins,
      inventories: inventories,
    );
    final rapport = await Descente(db, api, SyncRepository(db, api)).pull();
    expect(rapport.succeeded, isTrue, reason: rapport.error);
  }

  test("l'inventaire d'un collegue descend, avec ce qu'il a compte", () async {
    await descendre([_ouvert(biereComptee: 21)]);

    final inv = (await inventaires.watchOuvert(_economat).first)!;
    expect(inv.id, _inventaire);
    expect(inv.lignes, hasLength(2));
    final biere = inv.lignes.firstWhere((l) => l.productId == _biere);
    expect(biere.theorique, 24);
    expect(biere.compte, 21);
    expect(biere.ecart, -3);
    // Ici, on reprend le sien : en ouvrir un second est refuse.
    await expectLater(
      inventaires.ouvrir(magasinId: _economat, by: _agent),
      throwsStateError,
    );
  });

  test('abandonne ou clos ailleurs, il ne reste pas ouvert ici', () async {
    await descendre([_ouvert()]);
    expect(await inventaires.watchOuvert(_economat).first, isNotNull);

    await descendre([_ouvert(abandonne: DateTime.utc(2026, 10, 15, 9))]);
    expect(await inventaires.watchOuvert(_economat).first, isNull);

    await descendre([_ouvert(biereComptee: 24, statut: 'CLOSED')]);
    expect(await inventaires.watchOuvert(_economat).first, isNull);
  });

  test("un comptage pas encore remonte n'est pas ecrase", () async {
    await descendre([_ouvert()]);
    await inventaires.compter(
      inventaireId: _inventaire,
      productId: _biere,
      quantite: 18,
    );

    // Le serveur ne connait pas encore ce comptage.
    await descendre([_ouvert()]);

    final inv = (await inventaires.watchOuvert(_economat).first)!;
    expect(inv.lignes.firstWhere((l) => l.productId == _biere).compte, 18);
  });

  test('un serveur sans la route ne change rien', () async {
    await descendre(null);
    expect(await db.select(db.inventories).get(), isEmpty);
  });
}
