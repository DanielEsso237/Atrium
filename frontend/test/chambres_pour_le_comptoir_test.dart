/// Une tablette qui ne sert qu'au bar propose les chambres occupees.
///
/// Le barman porte sur la chambre sans lire les reservations : sans
/// `GET /chargeable-stays`, « Porter a la chambre » ne proposait aucune
/// chambre. Et le plafond du client doit se verifier ici avant le serveur :
/// un refus par la file la bloquerait.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _sejour = '01920000-0000-7000-8000-00000000c001';
const _dossier = '01920000-0000-7000-8000-00000000c002';
const _chambre = '01920000-0000-7000-8000-00000000c003';
const _categorie = '01920000-0000-7000-8000-00000000c004';
const _client = '01920000-0000-7000-8000-00000000c005';
const _ardoise = '01920000-0000-7000-8000-00000000c006';
const _nuitee = '01920000-0000-7000-8000-00000000c007';

RemoteChargeableStay _awaEn101({int plafond = 50000, int solde = 25000}) =>
    RemoteChargeableStay(
      stayId: _sejour,
      reservationId: _dossier,
      reservationReference: 'RES-0001',
      arrivalDate: '2026-10-10',
      departureDate: '2026-10-13',
      roomId: _chambre,
      roomNumber: '101',
      roomTypeId: _categorie,
      roomTypeCode: 'STD',
      roomTypeLabel: 'Standard',
      guestId: _client,
      guestCode: 'CLI-0001',
      firstName: 'Awa',
      lastName: 'Diallo',
      creditLimit: plafond,
      folio: RemoteFolio(
        id: _ardoise,
        number: 'FOL-0001',
        status: 'OPEN',
        type: 'GUEST',
        chargesTotal: solde,
        paymentsTotal: 0,
        balance: solde,
        guestId: _client,
        stayLineId: _sejour,
        items: [
          RemoteFolioItem(
            id: _nuitee,
            category: 'ROOM',
            label: 'Nuitee',
            quantity: 1,
            unitPrice: solde,
            amount: solde,
            businessDate: '2026-10-10',
          ),
        ],
      ),
    );

/// Le comptoir : il porte, mais ne lit pas les reservations.
class _Comptoir extends FakeCatalogApi {
  const _Comptoir({super.chargeableStays});

  @override
  Future<List<RemoteReservation>> fetchStaysInHouse() async =>
      throw const ApiException(ApiFailure.forbidden, 'reservation.read');
}

void main() {
  late AtriumDatabase db;

  setUp(() => db = AtriumDatabase.memory());
  tearDown(() => db.close());

  Future<PullReport> descendre(List<RemoteChargeableStay> sejours) {
    final api = _Comptoir(chargeableStays: sejours);
    return Descente(db, api, SyncRepository(db, api)).pull();
  }

  Future<List<ChargeableRoom>> chambres() =>
      OrderRepository(db).watchChargeableRooms().first;

  test('la chambre occupee se propose au comptoir, avec son solde', () async {
    final rapport = await descendre([_awaEn101()]);

    expect(rapport.succeeded, isTrue, reason: rapport.error);
    final liste = await chambres();
    expect(liste.map((c) => c.roomNumber), ['101']);
    expect(liste.single.guestName, 'Awa Diallo');
    expect(liste.single.folioId, _ardoise);
    expect(liste.single.balance, 25000);
  });

  test('le plafond du client se verifie avant le serveur', () async {
    await descendre([_awaEn101(plafond: 30000)]);

    // 25 000 + 6 000 = 31 000 : au-dela de 30 000.
    expect(
      () => FolioRepository(db).addCharge(
        folioId: _ardoise,
        category: ChargeCategory.FNB,
        label: 'Whisky',
        unitPrice: 6000,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('le client parti ne se propose plus', () async {
    await descendre([_awaEn101()]);

    await descendre(const []);

    expect(await chambres(), isEmpty);
  });

  test("un sejour en attente d'envoi n'est pas touche", () async {
    await descendre([_awaEn101()]);
    await (db.update(db.reservationRooms)
          ..where((rr) => rr.id.equals(_sejour)))
        .write(
          const ReservationRoomsCompanion(
            syncState: Value(SyncState.pending),
          ),
        );

    await descendre(const []);

    final rr = await (db.select(db.reservationRooms)
          ..where((r) => r.id.equals(_sejour)))
        .getSingle();
    expect(rr.status, ReservationStatus.CHECKED_IN);
  });

  test('une fiche client complete garde ses coordonnees', () async {
    final t0 = DateTime.utc(2026, 10, 1);
    await db
        .into(db.guests)
        .insert(
          GuestsCompanion.insert(
            id: _client,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            code: 'CLI-0001',
            firstName: 'Awa',
            lastName: 'Diallo',
            phone: const Value('+225 07 00 00 00'),
            syncState: const Value(SyncState.synced),
          ),
        );

    await descendre([_awaEn101(plafond: 80000)]);

    final fiche = await (db.select(db.guests)
          ..where((g) => g.id.equals(_client)))
        .getSingle();
    expect(fiche.phone, '+225 07 00 00 00');
    expect(fiche.creditLimit, 80000);
  });

  test("la reception, qui lit les reservations, n'appelle pas la route",
      () async {
    // FakeCatalogApi rend les sejours en cours : la reception. Ses chambres
    // a porter (s'il y en avait) ne doivent rien changer.
    final api = FakeCatalogApi(chargeableStays: [_awaEn101()]);
    await Descente(db, api, SyncRepository(db, api)).pull();

    expect(await chambres(), isEmpty);
  });
}
