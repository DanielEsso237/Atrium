/// L'ardoise ouverte par un check-in suit le serveur une fois remontee.
///
/// Vecu le 26 octobre : la tablette cree l'ardoise au check-in, en attente.
/// Le check-in remonte comme une ecriture du sejour (`reservation_rooms`) :
/// seul le sejour passait « a jour », l'ardoise restait en attente pour
/// toujours, et la descente ne la touchait plus. Encaissee le 24 depuis un
/// autre poste, elle affichait encore 25 000 a payer ; la reception a
/// encaisse une seconde fois, le serveur a refuse (« Ce folio est deja
/// solde ») et la file s'est bloquee.
library;

import 'dart:io';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

const _encaissementAilleurs = '01920000-0000-7000-8000-00000000c001';
const _admin = '01920000-0000-7000-8000-000000050001';

/// Un serveur qui garde l'ardoise de la tablette au check-in.
class _FauxApi extends ApiClient {
  _FauxApi(this.ardoise)
    : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final String Function() ardoise;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/check-in')) return {'folio_id': ardoise()};
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late FolioRepository folios;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    folios = FolioRepository(db);
  });

  tearDown(() => db.close());

  /// Un client arrive sur cette tablette ; renvoie son ardoise locale.
  Future<FolioRow> arrivee() async {
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    final chambre = await db
        .customSelect("SELECT id FROM rooms WHERE number = '101'")
        .getSingle();
    final reservations = ReservationRepository(db);
    final resId = await reservations.create(
      guestId: client.id,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime(2026, 10, 23),
      departure: DateTime(2026, 10, 24),
      nightlyRate: 25000,
      roomId: chambre.read<String>('id'),
    );
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(resId))).getSingle();
    await reservations.checkIn(lineId: ligne.id);
    return (await folios.openFolioForStay(ligne.id))!;
  }

  Future<FolioRow> relire(String id) =>
      (db.select(db.folios)..where((f) => f.id.equals(id))).getSingle();

  test('le check-in remonte : son ardoise passe a jour', () async {
    final ardoise = await arrivee();
    expect(ardoise.syncState, SyncState.pending);

    final rapport = await OutboxSender(
      db: db,
      api: _FauxApi(() => ardoise.id),
    ).drain();

    expect(rapport.arret, DrainStop.termine);
    expect((await relire(ardoise.id)).syncState, SyncState.synced);
  });

  test('encaissee sur un autre poste, elle tombe a zero ici', () async {
    final ardoise = await arrivee();
    await OutboxSender(db: db, api: _FauxApi(() => ardoise.id)).drain();
    final lignes = await (db.select(
      db.folioItems,
    )..where((i) => i.folioId.equals(ardoise.id))).get();

    // ADMIN01 encaisse le tout depuis un autre poste ; la descente le
    // rapporte, avec l'ardoise soldee.
    final api = FakeCatalogApi(
      folios: [
        RemoteFolio(
          id: ardoise.id,
          number: ardoise.number,
          status: 'OPEN',
          type: 'GUEST',
          chargesTotal: 25000,
          paymentsTotal: 25000,
          balance: 0,
          stayLineId: ardoise.reservationRoomId,
          guestId: ardoise.guestId,
          items: [
            for (final i in lignes)
              RemoteFolioItem(
                id: i.id,
                category: i.category.name,
                label: i.label,
                quantity: i.quantity,
                unitPrice: i.unitPrice,
                amount: i.amount,
                businessDate: i.businessDate,
              ),
          ],
        ),
      ],
      payments: [
        RemotePayment(
          id: _encaissementAilleurs,
          method: 'CASH',
          amount: 25000,
          folioId: ardoise.id,
          receivedBy: _admin,
        ),
      ],
    );
    await Descente(db, api, SyncRepository(db, api)).pull();

    final apres = await relire(ardoise.id);
    expect(apres.balance, 0);
    expect(apres.paymentsTotal, 25000);
  });

  test('tant que le check-in n a pas remonte, elle reste protegee', () async {
    final ardoise = await arrivee();
    final api = FakeCatalogApi(
      folios: [
        RemoteFolio(
          id: ardoise.id,
          number: 'FOL-999999',
          status: 'OPEN',
          type: 'GUEST',
          chargesTotal: 0,
          paymentsTotal: 0,
          balance: 0,
          items: const [],
        ),
      ],
    );
    await Descente(db, api, SyncRepository(db, api)).pull();

    expect((await relire(ardoise.id)).number, ardoise.number);
  });

  test('une tablette deja deployee retrouve ses ardoises coincees', () async {
    // Une base au schema 16 : un check-in remonte avec l'ancien moteur, son
    // ardoise coincee en attente, et un second check-in pas encore remonte.
    final dossier = await Directory.systemTemp.createTemp('atrium_');
    final fichier = File('${dossier.path}/atrium.sqlite');
    await db.close();
    var base = AtriumDatabase(NativeDatabase(fichier));
    db = base;
    await seedDemoData(base);
    folios = FolioRepository(base);
    final remontee = await arrivee();
    await (base.update(base.outboxEntries)).write(
      const OutboxEntriesCompanion(status: Value(OutboxStatus.ACKED)),
    );
    final client = await GuestRepository(
      base,
    ).create(firstName: 'Ibrahim', lastName: 'Sow');
    final chambre = await base
        .customSelect("SELECT id FROM rooms WHERE number = '102'")
        .getSingle();
    final reservations = ReservationRepository(base);
    final resId = await reservations.create(
      guestId: client.id,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime(2026, 10, 25),
      departure: DateTime(2026, 10, 26),
      nightlyRate: 25000,
      roomId: chambre.read<String>('id'),
    );
    final ligne = await (base.select(
      base.reservationRooms,
    )..where((rr) => rr.reservationId.equals(resId))).getSingle();
    await reservations.checkIn(lineId: ligne.id);
    final enAttente = (await FolioRepository(
      base,
    ).openFolioForStay(ligne.id))!;
    await base.customStatement('PRAGMA user_version = 16');
    await base.close();

    base = AtriumDatabase(NativeDatabase(fichier));
    db = base;
    Future<SyncState> etat(String id) async => (await (base.select(
      base.folios,
    )..where((f) => f.id.equals(id))).getSingle()).syncState;

    expect(await etat(remontee.id), SyncState.synced);
    expect(await etat(enAttente.id), SyncState.pending);
    await dossier.delete(recursive: true);
    // Deux semis (empreintes bcrypt) et une base sur disque : au milieu de la
    // suite complete, il depassait les trente secondes par defaut.
  }, timeout: const Timeout(Duration(minutes: 2)));
}
