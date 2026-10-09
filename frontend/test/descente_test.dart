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
    List<RemoteOutlet> outlets = const [],
  }) {
    final api = FakeCatalogApi(
      guests: guests,
      reservations: reservations,
      folios: folios,
      outlets: outlets,
    );
    return Descente(db, api, SyncRepository(db, api));
  }

  Future<int> compter(String table) async {
    final r = await db
        .customSelect('SELECT COUNT(*) AS n FROM $table')
        .getSingle();
    return r.read<int>('n');
  }

  test('un droit manquant saute la ressource, pas toute la descente',
      () async {
    // Vecu : la reception n'a pas le droit de lire les points de vente.
    // Ce 403 faisait echouer la descente entiere, et le poste de reception
    // ne recevait plus ni clients, ni reservations, ni ardoises.
    final api = _SansRestaurant(
      guests: [_guest()],
      reservations: [_reservation(typeStandard)],
      folios: [_folio()],
    );

    final rapport = await Descente(db, api, SyncRepository(db, api)).pull();

    expect(rapport.succeeded, isTrue);
    expect(rapport.outlets, 0);
    expect(await compter('guests'), 1);
    expect(await compter('reservation_rooms'), 1);
    expect(await compter('folio_items'), 1);
  });

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

  test('les arrhes descendent avec le dossier', () async {
    // Sans elles, une reservation saisie sur un autre poste n'affichait pas
    // ses arrhes dans la liste : ni payees, ni dues.
    final payees = DateTime.utc(2026, 9, 20, 10);
    final r = _reservation(typeStandard);
    await descente(
      guests: [_guest()],
      reservations: [
        RemoteReservation(
          id: r.id,
          reference: r.reference,
          guestId: r.guestId,
          status: r.status,
          arrivalDate: r.arrivalDate,
          departureDate: r.departureDate,
          adults: r.adults,
          children: r.children,
          rooms: r.rooms,
          depositAmount: 15000,
          depositPaidAt: payees,
        ),
      ],
    ).pull();

    final dossier = await db.select(db.reservations).getSingle();
    expect(dossier.depositAmount, 15000);
    expect(dossier.depositPaidAt?.toUtc(), payees);
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
      const CatalogApiHorsLigne(),
      SyncRepository(db, const CatalogApiHorsLigne()),
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

  test('les points de vente descendent avec leur ordre', () async {
    final rapport = await descente(
      outlets: const [
        RemoteOutlet(
          id: '01920000-0000-7000-8000-00000000e001',
          code: 'BAR',
          label: 'Bar',
          allowsRoomCharge: true,
          sortOrder: 2,
        ),
        RemoteOutlet(
          id: '01920000-0000-7000-8000-00000000e002',
          code: 'RESTAURANT',
          label: 'Restaurant',
          allowsRoomCharge: true,
          sortOrder: 1,
        ),
      ],
    ).pull();

    expect(rapport.outlets, 2);

    // L'ordre doit tenir : c'est lui qui rangera les onglets de l'ecran
    // Commande, et un ordre qui change d'une descente a l'autre deplacerait
    // les onglets sous les doigts de l'agent.
    final rangs = await db
        .customSelect('SELECT code FROM outlets ORDER BY sort_order')
        .get();
    expect(rangs.map((l) => l.read<String>('code')), ['RESTAURANT', 'BAR']);
  });

  test('un point de vente qui refuse la chambre le dit', () async {
    // Une boutique qui encaisse comptant : sa vente n'a rien a faire sur
    // l'ardoise d'un sejour.
    await descente(
      outlets: const [
        RemoteOutlet(
          id: '01920000-0000-7000-8000-00000000e003',
          code: 'BOUTIQUE',
          label: 'Boutique',
          allowsRoomCharge: false,
          sortOrder: 9,
        ),
      ],
    ).pull();

    final o = await db
        .customSelect("SELECT allows_room_charge AS a FROM outlets")
        .getSingle();
    expect(o.read<bool>('a'), isFalse);
  });

  test('une vente close ailleurs et son encaissement descendent', () async {
    const vente = '01920000-0000-7000-8000-00000000d010';
    const ligneVente = '01920000-0000-7000-8000-00000000d011';
    const paiement = '01920000-0000-7000-8000-00000000d012';
    const bar = '01920000-0000-7000-8000-00000000d013';
    const agent = '01920000-0000-7000-8000-00000000d014';
    final api = FakeCatalogApi(
      closedFolios: [
        RemoteFolio(
          id: vente,
          number: 'FOL-000099',
          status: 'CLOSED',
          type: 'WALK_IN',
          chargesTotal: 3000,
          paymentsTotal: 3000,
          balance: 0,
          items: [
            const RemoteFolioItem(
              id: ligneVente,
              category: 'FNB',
              label: 'Biere',
              quantity: 2,
              unitPrice: 1500,
              amount: 3000,
              businessDate: '2026-10-08',
              sourceTable: 'outlets',
              sourceId: bar,
              postedBy: agent,
            ),
          ],
        ),
      ],
      payments: [
        const RemotePayment(
          id: paiement,
          method: 'MOBILE_MONEY',
          amount: 3000,
          folioId: vente,
          receivedBy: agent,
          businessDate: '2026-10-08',
        ),
        // Un moyen que cette version ne connait pas : ecarte, pas range en
        // especes.
        const RemotePayment(
          id: '01920000-0000-7000-8000-00000000d015',
          method: 'CRYPTO',
          amount: 500,
          businessDate: '2026-10-08',
        ),
      ],
    );
    await Descente(db, api, SyncRepository(db, api)).pull();

    final ligne = await (db.select(
      db.folioItems,
    )..where((i) => i.id.equals(ligneVente))).getSingle();
    expect(ligne.sourceTable, 'outlets');
    expect(ligne.sourceId, bar);
    expect(ligne.postedBy, agent);

    final p = await (db.select(db.payments)).get();
    expect(p, hasLength(1));
    expect(p.single.method, PaymentMethod.MOBILE_MONEY);
    expect(p.single.receivedBy, agent);
    expect(p.single.businessDate, '2026-10-08');
  });
}

/// Le serveur tel que la reception le voit : le restaurant lui est refuse.
class _SansRestaurant extends FakeCatalogApi {
  const _SansRestaurant({super.guests, super.reservations, super.folios});

  Never _refus() =>
      throw const ApiException(ApiFailure.forbidden, 'restaurant.read');

  @override
  Future<List<RemoteOutlet>> fetchOutlets() async => _refus();

  @override
  Future<List<RemoteMenuCategory>> fetchMenuCategories() async => _refus();

  @override
  Future<List<RemoteMenuItem>> fetchMenuItems() async => _refus();
}
