/// Les permissions d'un role, depuis l'administration de la tablette.
///
/// La regle : on ne retire pas la derniere permission d'administration --
/// refusee ici, avant d'ecrire, comme le serveur la refuserait (409).
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/role_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

class _FauxApi extends ApiClient {
  _FauxApi() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final appels = <(String, Object?)>[];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    appels.add((path, body));
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late RoleRepository roles;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    roles = RoleRepository(db);
  });

  tearDown(() => db.close());

  Future<RoleView> role(String code) async =>
      (await roles.watchRoles().first).singleWhere((r) => r.role.code == code);

  test('la derniere permission d\'administration ne peut pas etre retiree',
      () async {
    final admin = await role('ADMIN');
    expect(admin.permissions, contains(adminPermission));
    final avant = (await db.select(db.outboxEntries).get()).length;

    await expectLater(
      roles.setPermissions(
        roleId: admin.role.id,
        codes: admin.permissions.difference({adminPermission}),
      ),
      throwsStateError,
    );

    expect((await role('ADMIN')).permissions, contains(adminPermission));
    expect((await db.select(db.outboxEntries).get()).length, avant);
  });

  test('les permissions d\'un role se remplacent et remontent en PUT',
      () async {
    final reception = await role('RECEPTION');

    await roles.setPermissions(
      roleId: reception.role.id,
      codes: {'rooms.read', 'guests.read'},
    );

    expect((await role('RECEPTION')).permissions, {'rooms.read', 'guests.read'});
    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();
    final (chemin, corps) = api.appels.single;
    expect(chemin, '/roles/RECEPTION/permissions');
    expect(corps, {
      'permissions': ['guests.read', 'rooms.read'],
    });
  });

  test('la descente aligne un role sur le serveur, sauf s\'il est en attente',
      () async {
    final api = FakeCatalogApi(
      roles: [
        {
          'code': 'RESTAURANT',
          'label': 'Restauration',
          'permissions': ['order.read', 'order.create'],
        },
      ],
      permissions: [
        {'code': 'order.create', 'label': 'Prendre une commande', 'module': 'order'},
      ],
    );

    await Descente(db, api, SyncRepository(db, api)).pull();

    expect((await role('RESTAURANT')).permissions, {'order.read', 'order.create'});
  });
}
