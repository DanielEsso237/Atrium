/// La descente des stocks.
///
/// Ce qui compte le plus : une quantite qui descend du serveur n'efface pas ce
/// que la tablette a fait sans l'avoir encore envoye -- une entree saisie
/// pendant la coupure, une biere vendue hors ligne.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _economat = '01920000-0000-7000-8000-00000000e001';
const _stockBar = '01920000-0000-7000-8000-00000000e002';
const _bar = '01920000-0000-7000-8000-00000000e003';
const _biere = '01920000-0000-7000-8000-00000000e004';
const _transfert = '01920000-0000-7000-8000-00000000e005';

const _magasins = [
  RemoteStockLocation(
    id: _economat, code: 'ECONOMAT', label: 'Économat', sortOrder: 0,
    isCentral: true,
  ),
  RemoteStockLocation(
    id: _stockBar, code: 'BAR', label: 'Bar', sortOrder: 1, isCentral: false,
    outletId: _bar,
  ),
];

const _produits = [
  RemoteProduct(
    id: _biere, reference: 'BIERE', label: 'Biere 65 cl', unit: 'U',
    purchasePrice: 600, salePrice: 1500, minStock: 6,
  ),
];

const _attente = RemoteStockMovement(
  id: _transfert, productId: _biere, locationId: _economat, type: 'TRANSFER',
  quantity: 24, status: 'PENDING', counterpartLocationId: _stockBar,
);

/// Le serveur refuse de lire les transferts : l'agent n'a pas stock.read.
class _SansStocks extends FakeCatalogApi {
  const _SansStocks();

  @override
  Future<List<RemoteStockMovement>> fetchPendingTransfers() async =>
      throw const ApiException(ApiFailure.forbidden, 'stock.read');
}

void main() {
  late AtriumDatabase db;

  setUp(() => db = AtriumDatabase.memory());
  tearDown(() => db.close());

  Future<void> descendre({
    int auBar = 10,
    List<RemoteStockMovement> transferts = const [_attente],
  }) async {
    final api = FakeCatalogApi(
      products: _produits,
      stockLocations: _magasins,
      stockLevels: [
        RemoteStockLevel(productId: _biere, locationId: _stockBar, quantity: auBar),
      ],
      pendingTransfers: transferts,
    );
    final rapport = await Descente(db, api, SyncRepository(db, api)).pull();
    expect(rapport.succeeded, isTrue, reason: rapport.error);
  }

  Future<int> auBar() async => (await (db.select(db.stockLevels)..where(
            (l) => l.productId.equals(_biere) & l.stockLocationId.equals(_stockBar),
          ))
          .getSingle())
      .quantity;

  Future<void> mouvement({
    required String id,
    required StockMovementType type,
    required int quantite,
    SyncState etat = SyncState.pending,
    StockMovementStatus statut = StockMovementStatus.APPROVED,
    String? sourceTable,
    String? sourceId,
  }) async {
    final now = DateTime.now().toUtc();
    await db
        .into(db.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            productId: _biere,
            stockLocationId: _stockBar,
            type: type,
            quantity: quantite,
            status: Value(statut),
            sourceTable: Value(sourceTable),
            sourceId: Value(sourceId),
            syncState: Value(etat),
          ),
        );
  }

  test('une tablette neuve recoit produits, magasins, quantites, transferts',
      () async {
    await descendre();

    final economat = await (db.select(
      db.stockLocations,
    )..where((m) => m.isCentral.equals(true))).getSingle();
    expect(economat.code, 'ECONOMAT');
    final bar = await (db.select(
      db.stockLocations,
    )..where((m) => m.id.equals(_stockBar))).getSingle();
    expect(bar.outletId, _bar);
    expect((await db.select(db.products).getSingle()).minStock, 6);
    expect(await auBar(), 10);
    final t = await db.select(db.stockMovements).getSingle();
    expect(t.status, StockMovementStatus.PENDING);
  });

  test('une entree saisie hors ligne n est pas effacee par la descente',
      () async {
    await descendre();
    await mouvement(id: newId(), type: StockMovementType.IN, quantite: 5);

    // Le serveur dit encore 10 : il ne connait pas l'entree.
    await descendre();
    expect(await auBar(), 15);
  });

  test('une vente pas encore remontee reste deduite', () async {
    await descendre();
    final now = DateTime.now().toUtc();
    final ardoise = newId();
    final ligne = newId();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: ardoise, createdAt: now, updatedAt: now, hotelId: _hotel,
            number: 'FOL-T',
          ),
        );
    await db
        .into(db.folioItems)
        .insert(
          FolioItemsCompanion.insert(
            id: ligne, createdAt: now, updatedAt: now, folioId: ardoise,
            category: ChargeCategory.FNB, label: 'Biere', businessDate: '2026-10-08',
            syncState: const Value(SyncState.pending),
          ),
        );
    // La sortie de vente ne remonte pas d'elle-meme : elle part avec sa ligne.
    await mouvement(
      id: newId(), type: StockMovementType.OUT, quantite: 2,
      etat: SyncState.synced, sourceTable: 'folio_items', sourceId: ligne,
    );

    await descendre();
    expect(await auBar(), 8);

    // La ligne remontee, le serveur a fait sortir les deux bieres lui-meme.
    await (db.update(db.folioItems)..where((i) => i.id.equals(ligne))).write(
      const FolioItemsCompanion(syncState: Value(SyncState.synced)),
    );
    await descendre(auBar: 8);
    expect(await auBar(), 8);
  });

  test('un transfert valide ailleurs quitte la liste a valider', () async {
    await descendre();
    // Une demande faite ici et pas encore remontee, elle, reste.
    final demande = newId();
    await mouvement(
      id: demande, type: StockMovementType.TRANSFER, quantite: 3,
      statut: StockMovementStatus.PENDING,
    );

    await descendre(transferts: const []);
    final restants = await db.select(db.stockMovements).get();
    expect(restants.map((m) => m.id), [demande]);
  });

  test('sans le droit de lire les stocks, rien n est retire', () async {
    await descendre();
    final api = const _SansStocks();
    await Descente(db, api, SyncRepository(db, api)).pull();
    expect(await db.select(db.stockMovements).get(), hasLength(1));
  });
}
