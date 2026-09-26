/// La descente : du serveur vers la base locale.
///
/// Deux choses a prouver, et la seconde compte plus que la premiere.
///
/// Qu'une base vide se remplisse — c'est ce qui rend une tablette neuve ou
/// reinitialisee utilisable, au lieu d'aveugle.
///
/// Et qu'elle **n'ecrase jamais** ce qui n'est pas encore remonte. Une
/// descente qui ferait disparaitre un check-in saisi il y a trente secondes
/// serait pire que pas de descente du tout : la premiere laisse une tablette
/// en retard, la seconde fait perdre du travail sans le dire.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _client = '01920000-0000-7000-8000-00000000d001';
const _dossier = '01920000-0000-7000-8000-00000000d002';
const _ligne = '01920000-0000-7000-8000-00000000d003';
const _ardoise = '01920000-0000-7000-8000-00000000d004';
const _item = '01920000-0000-7000-8000-00000000d005';

RemoteGuest _guest({String nom = 'Diallo'}) => RemoteGuest(
  id: _client,
  code: 'CLI-00001',
  firstName: 'Awa',
  lastName: nom,
  phone: '0700000000',
);

RemoteReservation _reservation(String roomTypeId, {String statut = 'CONFIRMED'}) =>
    RemoteReservation(
      id: _dossier,
      reference: 'RES-000001',
      guestId: _client,
      status: statut,
      arrivalDate: '2026-09-24',
      departureDate: '2026-09-26',
      adults: 2,
      children: 0,
      rooms: [
        RemoteStayLine(
          id: _ligne,
          roomTypeId: roomTypeId,
          status: statut,
          arrivalDate: '2026-09-24',
          departureDate: '2026-09-26',
          adults: 2,
          children: 0,
          nightlyRate: 25000,
        ),
      ],
    );

RemoteFolio _folio({int balance = 25000}) => RemoteFolio(
  id: _ardoise,
  number: 'FOL-000001',
  status: 'OPEN',
  type: 'GUEST',
  chargesTotal: 25000,
  paymentsTotal: 25000 - balance,
  balance: balance,
  guestId: _client,
  stayLineId: _ligne,
  items: [
    const RemoteFolioItem(
      id: _item,
      category: 'ROOM',
      label: 'Nuitee',
      quantity: 1,
      unitPrice: 25000,
      amount: 25000,
      businessDate: '2026-09-24',
    ),
  ],
);

void main() {
  late AtriumDatabase db;
  late String typeStandard;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    typeStandard = roomTypeSeeds.first.id;
  });

  tearDown(() => db.close());

  Descente descente({
    List<RemoteGuest> guests = const [],
    List<RemoteReservation> reservations = const [],
    List<RemoteFolio> folios = const [],
  }) {
    final api = FakeCatalogApi(
      guests: guests,
      reservations: reservations,
      folios: folios,
    );
    return Descente(db, api, SyncRepository(db, api));
  }

  Future<int> compter(String table) async {
    final r = await db
        .customSelect('SELECT COUNT(*) AS n FROM $table')
        .getSingle();
    return r.read<int>('n');
  }

  test('une base vide se remplit entierement', () async {
    // Le cas d'une tablette neuve : ses donnees sont sur le serveur, elle
    // doit savoir aller les chercher.
    final rapport = await descente(
      guests: [_guest()],
      reservations: [_reservation(typeStandard)],
      folios: [_folio()],
    ).pull();

    expect(rapport.succeeded, isTrue);
    expect(rapport.guests, 1);
    expect(rapport.reservations, 1);
    expect(rapport.stayLines, 1);
    expect(rapport.folios, 1);
    expect(rapport.items, 1);

    expect(await compter('guests'), 1);
    expect(await compter('reservation_rooms'), 1);
    expect(await compter('folio_items'), 1);
  });

  test('les lignes descendues sont marquees synced', () async {
    await descente(guests: [_guest()]).pull();

    final g = await (db.select(
      db.guests,
    )..where((g) => g.id.equals(_client))).getSingle();

    // Elles viennent du serveur : les laisser `pending` les ferait remonter
    // aussitot, et la file tournerait en rond.
    expect(g.syncState, SyncState.synced);
  });

  test('une descente relancee met a jour sans dupliquer', () async {
    await descente(guests: [_guest()]).pull();
    await descente(guests: [_guest(nom: 'Kone')]).pull();

    expect(await compter('guests'), 1);
    final g = await (db.select(
      db.guests,
    )..where((g) => g.id.equals(_client))).getSingle();
    expect(g.lastName, 'Kone');
  });

  test('une ligne en attente n est pas ecrasee', () async {
    // Le coeur du ticket. Un client cree sur la tablette et pas encore
    // remonte doit survivre a une descente qui porte une autre version.
    final now = DateTime.now().toUtc();
    await db.into(db.guests).insert(
          GuestsCompanion.insert(
            id: _client,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            code: 'CLI-00001',
            firstName: 'Awa',
            lastName: 'SAISIE LOCALE',
            syncState: const Value(SyncState.pending),
          ),
        );

    final rapport = await descente(guests: [_guest(nom: 'VERSION SERVEUR')]).pull();

    final g = await (db.select(
      db.guests,
    )..where((g) => g.id.equals(_client))).getSingle();
    expect(g.lastName, 'SAISIE LOCALE');
    expect(rapport.guests, 0);
    expect(rapport.skipped, 1);
  });

  test('une fois remontee, la meme ligne est bien mise a jour', () async {
    // L'autre moitie de la regle : une barriere qui ne se leve jamais
    // paralyse la tablette au lieu de la proteger.
    final now = DateTime.now().toUtc();
    await db.into(db.guests).insert(
          GuestsCompanion.insert(
            id: _client,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            code: 'CLI-00001',
            firstName: 'Awa',
            lastName: 'SAISIE LOCALE',
            syncState: const Value(SyncState.synced),
          ),
        );

    await descente(guests: [_guest(nom: 'VERSION SERVEUR')]).pull();

    final g = await (db.select(
      db.guests,
    )..where((g) => g.id.equals(_client))).getSingle();
    expect(g.lastName, 'VERSION SERVEUR');
  });

  test('une reservation sans son client est ecartee, pas fatale', () async {
    // Le client n'est pas descendu : la cle etrangere refuserait la ligne et
    // l'exception ferait tomber toute la transaction, donc tout le lot.
    final rapport = await descente(
      reservations: [_reservation(typeStandard)],
    ).pull();

    expect(rapport.succeeded, isTrue);
    expect(rapport.reservations, 0);
    expect(rapport.skipped, greaterThan(0));
    expect(await compter('reservations'), 0);
  });

  test('une categorie de chambre inconnue ecarte la ligne, pas le dossier', () async {
    final rapport = await descente(
      guests: [_guest()],
      reservations: [_reservation('01920000-0000-7000-8000-00000000ffff')],
    ).pull();

    expect(rapport.reservations, 1);
    expect(rapport.stayLines, 0);
    expect(await compter('reservation_rooms'), 0);
  });

  test('hors ligne, rien n est ecrit et ce n est pas une erreur', () async {
    final rapport = await Descente(
      db,
      const _ApiHorsLigne(),
      SyncRepository(db, const _ApiHorsLigne()),
    ).pull();

    expect(rapport.offline, isTrue);
    expect(rapport.succeeded, isFalse);
    expect(rapport.error, isNull);
    expect(await compter('guests'), 0);
  });

  test('l ardoise descend avec ses lignes et son solde', () async {
    await descente(
      guests: [_guest()],
      reservations: [_reservation(typeStandard)],
      folios: [_folio(balance: 5000)],
    ).pull();

    final f = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(_ardoise))).getSingle();
    expect(f.balance, 5000);
    expect(f.reservationRoomId, _ligne);
    expect(await compter('folio_items'), 1);
  });
}

/// Un serveur injoignable.
class _ApiHorsLigne implements CatalogApi {
  const _ApiHorsLigne();

  Never _couloir() =>
      throw const ApiException(ApiFailure.offline, 'injoignable');

  @override
  Future<List<RemoteRoom>> fetchRooms() async => _couloir();

  @override
  Future<List<RemoteGuest>> fetchGuests() async => _couloir();

  @override
  Future<List<RemoteReservation>> fetchReservations({
    DateTime? from,
    DateTime? to,
    int joursAvant = 7,
    int joursApres = 30,
  }) async => _couloir();

  @override
  Future<List<RemoteFolio>> fetchOpenFolios() async => _couloir();
}
