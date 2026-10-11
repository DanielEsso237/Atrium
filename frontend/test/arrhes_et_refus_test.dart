/// Les arrhes survivent a la descente, et un encaissement refuse se retire.
///
/// Vecu le 11 octobre : la descente des paiements effacait la note
/// « Arrhes RES-... ». Au check-in, la tablette ne retrouvait plus les
/// arrhes, croyait le sejour entier du, et l'encaissement du tout etait
/// refuse par le serveur -- avec huit saisies bloquees derriere, sans moyen
/// de s'en sortir.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/ecriture_refusee.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _agent = '01920000-0000-7000-8000-000000050002';
const _paiement = '01920000-0000-7000-8000-00000000e001';
const _ardoise = '01920000-0000-7000-8000-00000000e002';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
  });

  tearDown(() => db.close());

  Future<void> descendre(List<RemotePayment> paiements) {
    final api = FakeCatalogApi(payments: paiements);
    return Descente(db, api, SyncRepository(db, api)).pull();
  }

  Future<String?> note() async => (await (db.select(db.payments)
        ..where((p) => p.id.equals(_paiement)))
      .getSingle()).notes;

  group('la note des arrhes', () {
    setUp(() async {
      final now = DateTime.now().toUtc();
      await db
          .into(db.payments)
          .insert(
            PaymentsCompanion.insert(
              id: _paiement, createdAt: now, updatedAt: now, hotelId: _hotel,
              method: PaymentMethod.CASH, amount: 7500,
              notes: const Value('Arrhes RES-000001'),
              syncState: const Value(SyncState.synced),
            ),
          );
    });

    test('un serveur qui ne l envoie pas ne l efface plus', () async {
      await descendre([
        const RemotePayment(id: _paiement, method: 'CASH', amount: 7500),
      ]);
      expect(await note(), 'Arrhes RES-000001');
    });

    test('un serveur qui l envoie la donne', () async {
      await descendre([
        const RemotePayment(
          id: _paiement, method: 'CASH', amount: 7500,
          notes: 'Arrhes RES-000002',
        ),
      ]);
      expect(await note(), 'Arrhes RES-000002');
    });
  });

  test('un encaissement refuse se retire, et l ardoise se recalcule',
      () async {
    final now = DateTime.now().toUtc();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: _ardoise, createdAt: now, updatedAt: now, hotelId: _hotel,
            number: 'FOL-000029',
          ),
        );
    final ardoises = FolioRepository(db);
    await ardoises.addCharge(
      folioId: _ardoise,
      category: ChargeCategory.ROOM,
      label: 'Nuitee',
      unitPrice: 25000,
    );
    await CashRepository(db).open(userId: _agent, openingFloat: 0);
    await ardoises.addPayment(
      folioId: _ardoise,
      method: PaymentMethod.CASH,
      amount: 25000,
      receivedBy: _agent,
    );
    // Le serveur l'a refuse : la file est bloquee sur lui.
    await (db.update(db.outboxEntries)
          ..where((o) => o.entityTable.equals('payments')))
        .write(
          const OutboxEntriesCompanion(
            status: Value(OutboxStatus.FAILED),
            lastError: Value('Il ne reste que 17500 a encaisser sur ce folio.'),
          ),
        );

    final refusee = (await ecritureRefusee(db))!;
    expect(refusee.retirable, isTrue);
    expect(refusee.raison, contains('17500'));

    await retirerEcritureRefusee(db, refusee);

    expect(await db.select(db.payments).get(), isEmpty);
    expect(await ecritureRefusee(db), isNull);
    final ardoise = await (db.select(db.folios)
          ..where((f) => f.id.equals(_ardoise)))
        .getSingle();
    expect(ardoise.balance, 25000);
  });

  test('une ecriture qui n est pas un encaissement ne se retire pas', () {
    const e = EcritureRefusee(
      entreeId: 1,
      table: 'reservations',
      ligneId: _ardoise,
      operation: SyncOp.INSERT,
    );
    expect(e.retirable, isFalse);
    expect(() => retirerEcritureRefusee(db, e), throwsStateError);
  });
}
