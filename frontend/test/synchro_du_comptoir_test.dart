/// Le comptoir ne lit pas le plan des chambres : ce refus n'est pas une panne.
///
/// Vu le 12 octobre : a chaque synchronisation, le barman voyait « erreur :
/// permission rooms.read », alors que ses chambres lui arrivaient bien par
/// `GET /chargeable-stays` et que tout le reste passait.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

class _SansPlanDesChambres extends FakeCatalogApi {
  const _SansPlanDesChambres();

  @override
  Future<List<RemoteRoom>> fetchRooms() async =>
      throw const ApiException(ApiFailure.forbidden, 'rooms.read');
}

class _ServeurEnPanne extends FakeCatalogApi {
  const _ServeurEnPanne();

  @override
  Future<List<RemoteRoom>> fetchRooms() async =>
      throw const ApiException(ApiFailure.server, 'panne');
}

void main() {
  late AtriumDatabase db;

  setUp(() => db = AtriumDatabase.memory());
  tearDown(() => db.close());

  test("sans le droit de lire le plan, la synchro n'est pas en erreur", () async {
    const api = _SansPlanDesChambres();

    final issue = await SyncRepository(db, api).pullRooms();

    expect(issue.error, isNull);
    expect(issue.offline, isFalse);
  });

  test('une vraie panne reste une erreur', () async {
    const api = _ServeurEnPanne();

    final issue = await SyncRepository(db, api).pullRooms();

    expect(issue.error, isNotNull);
  });
}
