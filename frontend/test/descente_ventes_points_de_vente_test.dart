/// La descente des ventes d'un point de vente (`GET /outlet-activity`).
///
/// L'agent du bar ne lit ni les ardoises ni les encaissements de l'hotel :
/// sans elle, son tableau de bord ne voyait que ce que sa tablette avait
/// vendu. Elle apporte les lignes de ses points de vente avec l'en-tete seul
/// de leur ardoise -- et ne doit jamais abimer une ardoise complete deja la.
library;

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
const _bar = '01920000-0000-7000-8000-00000000b001';
const _ardoiseChambre = '01920000-0000-7000-8000-00000000b002';
const _ardoisePassage = '01920000-0000-7000-8000-00000000b003';
const _biere = '01920000-0000-7000-8000-00000000b004';
const _soda = '01920000-0000-7000-8000-00000000b005';
const _encaissement = '01920000-0000-7000-8000-00000000b006';
const _tiroirCollegue = '01920000-0000-7000-8000-00000000b007';
const _collegue = '01920000-0000-7000-8000-00000000b008';

final _saisie = DateTime.utc(2026, 10, 11, 19, 42);

RemoteOutletSale _vente(
  String id,
  String folio,
  String type, {
  String label = 'Biere',
  int montant = 3000,
}) => RemoteOutletSale(
  item: RemoteFolioItem(
    id: id,
    category: 'FNB',
    label: label,
    quantity: 1,
    unitPrice: montant,
    amount: montant,
    businessDate: '2026-10-11',
    sourceTable: 'outlets',
    sourceId: _bar,
    postedBy: _collegue,
    postedAt: _saisie,
  ),
  folioId: folio,
  folioNumber: 'FOL-$id'.substring(0, 12),
  folioType: type,
  folioStatus: type == 'WALK_IN' ? 'CLOSED' : 'OPEN',
);

final _soiree = RemoteOutletActivity(
  sales: [
    _vente(_biere, _ardoiseChambre, 'GUEST'),
    _vente(_soda, _ardoisePassage, 'WALK_IN', label: 'Soda', montant: 1500),
  ],
  payments: const [
    RemotePayment(
      id: _encaissement,
      method: 'CASH',
      amount: 1500,
      folioId: _ardoisePassage,
      cashSessionId: _tiroirCollegue,
      receivedBy: _collegue,
      businessDate: '2026-10-11',
    ),
  ],
  cashSessions: [
    RemoteCashSession(
      id: _tiroirCollegue,
      userId: _collegue,
      status: 'OPEN',
      openedAt: DateTime.utc(2026, 10, 11, 17),
      outletId: _bar,
    ),
  ],
);

/// Un serveur qui refuse l'activite, ou ne la connait pas encore.
class _Refus extends FakeCatalogApi {
  const _Refus(this.echec);

  final ApiFailure echec;

  @override
  Future<RemoteOutletActivity> fetchOutletActivity(DateTime since) async =>
      throw ApiException(echec, 'outlet-activity');
}

void main() {
  late AtriumDatabase db;

  setUp(() => db = AtriumDatabase.memory());
  tearDown(() => db.close());

  Future<PullReport> descendre(CatalogApi api) =>
      Descente(db, api, SyncRepository(db, api)).pull();

  Future<FolioItemRow?> ligne(String id) =>
      (db.select(db.folioItems)..where((i) => i.id.equals(id)))
          .getSingleOrNull();

  Future<FolioRow?> ardoise(String id) =>
      (db.select(db.folios)..where((f) => f.id.equals(id))).getSingleOrNull();

  test('les ventes du bar descendent, rattachees au bar, a leur heure', () async {
    final rapport = await descendre(FakeCatalogApi(outletActivity: _soiree));

    expect(rapport.succeeded, isTrue, reason: rapport.error);
    final biere = await ligne(_biere);
    expect(biere, isNotNull);
    expect(biere!.sourceTable, 'outlets');
    expect(biere.sourceId, _bar);
    expect(biere.postedBy, _collegue);
    // L'heure de la saisie, pas celle de la descente : les heures de pointe
    // se lisent dessus.
    expect(biere.postedAt, _saisie);
    expect((await ligne(_soda))!.amount, 1500);
  });

  test("l'ardoise de la chambre arrive en en-tete seul, sans totaux", () async {
    await descendre(FakeCatalogApi(outletActivity: _soiree));

    final chambre = await ardoise(_ardoiseChambre);
    expect(chambre!.type, FolioType.GUEST);
    expect(chambre.status, FolioStatus.OPEN);
    expect(chambre.guestId, isNull);
    expect(chambre.balance, 0);
    expect((await ardoise(_ardoisePassage))!.type, FolioType.WALK_IN);
  });

  test("une ardoise complete deja la garde ses totaux", () async {
    final complete = RemoteFolio(
      id: _ardoiseChambre,
      number: 'FOL-0001',
      status: 'OPEN',
      type: 'GUEST',
      chargesTotal: 28000,
      paymentsTotal: 0,
      balance: 28000,
      items: const [],
    );

    await descendre(
      FakeCatalogApi(folios: [complete], outletActivity: _soiree),
    );

    final chambre = await ardoise(_ardoiseChambre);
    expect(chambre!.number, 'FOL-0001');
    expect(chambre.balance, 28000);
    expect(await ligne(_biere), isNotNull);
  });

  test("l'encaissement et le tiroir d'un collegue descendent", () async {
    await descendre(FakeCatalogApi(outletActivity: _soiree));

    final paiement = await (db.select(db.payments)
          ..where((p) => p.id.equals(_encaissement)))
        .getSingleOrNull();
    expect(paiement?.cashSessionId, _tiroirCollegue);
    final tiroir = await (db.select(db.cashSessions)
          ..where((c) => c.id.equals(_tiroirCollegue)))
        .getSingleOrNull();
    expect(tiroir?.outletId, _bar);
    expect(tiroir?.status, CashSessionStatus.OPEN);
  });

  test("une vente modifiee ici et pas encore remontee n'est pas ecrasee",
      () async {
    final maintenant = DateTime.now().toUtc();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: _ardoiseChambre,
            createdAt: maintenant,
            updatedAt: maintenant,
            hotelId: _hotel,
            number: 'FOL-LOCAL',
          ),
        );
    await db
        .into(db.folioItems)
        .insert(
          FolioItemsCompanion.insert(
            id: _biere,
            createdAt: maintenant,
            updatedAt: maintenant,
            folioId: _ardoiseChambre,
            category: ChargeCategory.FNB,
            label: 'Biere annulee ici',
            businessDate: '2026-10-11',
            isVoid: const Value(true),
            syncState: const Value(SyncState.pending),
          ),
        );

    final rapport = await descendre(FakeCatalogApi(outletActivity: _soiree));

    expect(rapport.skipped, greaterThanOrEqualTo(1));
    final biere = await ligne(_biere);
    expect(biere!.isVoid, isTrue);
    expect(biere.label, 'Biere annulee ici');
  });

  for (final echec in [ApiFailure.forbidden, ApiFailure.notFound]) {
    test("un refus ($echec) n'empeche pas le reste de la descente", () async {
      final rapport = await descendre(_Refus(echec));

      expect(rapport.succeeded, isTrue, reason: rapport.error);
    });
  }
}
