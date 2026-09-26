/// La barriere qui empeche une descente d'ecraser le travail d'un agent.
///
/// Tant qu'une modification n'est pas remontee, la version locale fait foi :
/// c'est le serveur qui est en retard, pas la tablette. L'ecraser ferait
/// disparaitre un check-in ou une reservation que quelqu'un vient de saisir,
/// sans trace et sans avertissement — le pire genre de perte, celui qu'on ne
/// decouvre que quand le client se plaint.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

void main() {
  late AtriumDatabase db;
  late SyncRepository repo;

  const hotel = '01920000-0000-7000-8000-000000000001';
  const clientId = '01920000-0000-7000-8000-00000000d001';

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    repo = SyncRepository(db, const FakeCatalogApi());
  });

  tearDown(() => db.close());

  Future<void> creerClient({required SyncState etat}) async {
    final now = DateTime.now().toUtc();
    await db.into(db.guests).insert(
          GuestsCompanion.insert(
            id: clientId,
            createdAt: now,
            updatedAt: now,
            hotelId: hotel,
            code: 'CLI-00001',
            firstName: 'Awa',
            lastName: 'Diallo',
            syncState: Value(etat),
          ),
        );
  }

  Future<void> enfiler(String table, String id, OutboxStatus etat) async {
    await db.into(db.outboxEntries).insert(
          OutboxEntriesCompanion.insert(
            entityTable: table,
            entityId: id,
            op: SyncOp.INSERT,
            payload: '{}',
            createdAt: DateTime.now().toUtc(),
            status: Value(etat),
          ),
        );
  }

  test('une ligne marquee pending est protegee', () async {
    await creerClient(etat: SyncState.pending);

    expect(await repo.lignesEnAttente(db.guests), contains(clientId));
  });

  test('une ligne deja remontee ne l est pas', () async {
    await creerClient(etat: SyncState.synced);

    // Sinon la descente n'ecrirait jamais rien : tout serait protege pour
    // toujours, et la tablette resterait aveugle.
    expect(await repo.lignesEnAttente(db.guests), isEmpty);
  });

  test('une entree en file protege sa ligne', () async {
    await creerClient(etat: SyncState.synced);
    await enfiler('guests', clientId, OutboxStatus.PENDING);

    expect(await repo.lignesEnAttente(db.guests), contains(clientId));
  });

  test('une entree en echec protege encore', () async {
    // Une entree FAILED sera rejouee : son intention tient toujours. La
    // traiter comme acquittee ferait perdre l'ecriture au moment meme ou elle
    // a le plus besoin d'etre protegee.
    await creerClient(etat: SyncState.synced);
    await enfiler('guests', clientId, OutboxStatus.FAILED);

    expect(await repo.lignesEnAttente(db.guests), contains(clientId));
  });

  test('une entree acquittee ne protege plus', () async {
    await creerClient(etat: SyncState.synced);
    await enfiler('guests', clientId, OutboxStatus.ACKED);

    expect(await repo.lignesEnAttente(db.guests), isEmpty);
  });

  test('la protection ne deborde pas sur une autre table', () async {
    // Une reservation en attente ne doit pas figer les clients : ce sont deux
    // tables, et l'entree nomme la sienne.
    await creerClient(etat: SyncState.synced);
    await enfiler('reservations', clientId, OutboxStatus.PENDING);

    expect(await repo.lignesEnAttente(db.guests), isEmpty);
    expect(await repo.lignesEnAttente(db.reservations), contains(clientId));
  });

  test('la barriere vaut pour chaque table metier', () async {
    // Elle doit marcher partout, pas seulement la ou on l'a ecrite.
    final tables = <TableInfo>[
      db.guests,
      db.reservations,
      db.reservationRooms,
      db.folios,
      db.folioItems,
      db.payments,
    ];

    for (var i = 0; i < tables.length; i++) {
      final table = tables[i];
      // `entity_id` est une colonne d'UUID : 36 caracteres exiges.
      final id = '01920000-0000-7000-8000-0000000e${i.toString().padLeft(4, '0')}';
      await enfiler(table.actualTableName, id, OutboxStatus.PENDING);
      expect(
        await repo.lignesEnAttente(table),
        contains(id),
        reason: table.actualTableName,
      );
    }
  });
}
