/// Les agents crees depuis l'administration, et ceux que le serveur decrit.
///
/// Le point dur : un agent cree sur un poste doit avoir ses droits sur un
/// autre, que ces droits se lisent en local. A la connexion en ligne, le
/// serveur les decrit (`/auth/me`), et la tablette les enregistre.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/agent_repository.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _FauxApi extends ApiClient {
  _FauxApi() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final appels = <(String, String, Map<String, Object?>)>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    appels.add(('POST', path, (body as Map).cast<String, Object?>()));
    return {};
  }

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    appels.add(('PATCH', path, (body as Map).cast<String, Object?>()));
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late AgentRepository agents;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    agents = AgentRepository(db);
  });

  tearDown(() => db.close());

  test('un agent decrit par le serveur recoit ses droits ici', () async {
    const id = '01920000-0000-7000-8000-00000000e001';

    await agents.applyServerAgent({
      'id': id,
      'employee_code': 'bar01',
      'first_name': 'Ines',
      'last_name': 'Mbarga',
      'is_active': true,
      'roles': [
        {
          'code': 'BARMAN',
          'label': 'Barman',
          'permissions': ['order.read', 'order.create'],
        },
      ],
      'outlet_ids': ['01920000-0000-7000-8000-00000000b001'],
    });

    final acces = await accessProfileFor(db, id);
    expect(acces.peut('order.read'), isTrue);
    expect(acces.peut('guests.read'), isFalse);
    final u = await (db.select(db.users)..where((u) => u.id.equals(id)))
        .getSingle();
    expect(u.employeeCode, 'BAR01');
    expect(u.firstName, 'Ines');
  });

  test("un role decrit sans ses permissions n'efface rien", () async {
    // Vecu : un serveur pas encore a jour renvoie les roles sans leurs
    // permissions. L'administrateur perdait tous ses modules a la connexion.
    final admin = await (db.select(db.users)
          ..where((u) => u.employeeCode.equals('ADMIN01')))
        .getSingle();

    await agents.applyServerAgent({
      'id': admin.id,
      'employee_code': 'ADMIN01',
      'first_name': 'Admin',
      'last_name': 'Atrium',
      'roles': [
        {'code': 'ADMIN', 'label': 'Administrateur'},
      ],
    });

    final acces = await accessProfileFor(db, admin.id);
    expect(acces.peut('rooms.read'), isTrue);
    expect(acces.peut('users.write'), isTrue);
  });

  test("un agent hors Commandes part sans points de vente", () async {
    final reception = (await agents.roles()).firstWhere(
      (r) => r.code == 'RECEPTION',
    );
    await agents.create(
      employeeCode: 'REC02',
      firstName: 'Awa',
      lastName: 'Traore',
      pin: '4321',
      roleCode: reception.code,
      outletIds: ['01920000-0000-7000-8000-00000000b001'],
    );
    final api = _FauxApi();

    await OutboxSender(db: db, api: api).drain();

    expect(api.appels.single.$3['outlet_ids'], isEmpty);
    expect(await db.select(db.userOutlets).get(), isEmpty);
  });

  test("redonner un PIN part vers reset-pin, puis s'efface", () async {
    final admin = await (db.select(db.users)
          ..where((u) => u.employeeCode.equals('RECEP01')))
        .getSingle();

    await agents.resetPin(id: admin.id, pin: '9876');
    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();

    final (methode, chemin, corps) = api.appels.single;
    expect((methode, chemin), ('POST', '/users/${admin.id}/reset-pin'));
    expect(corps, {'new_pin': '9876'});
    final restes = await db.select(db.outboxEntries).get();
    expect(
      restes.map((e) => (jsonDecode(e.payload) as Map).containsKey('pin')),
      everyElement(isFalse),
    );
    await expectLater(
      agents.resetPin(id: admin.id, pin: '12'),
      throwsStateError,
    );
  });

  test('creer un agent part en POST, avec son PIN, une seule fois', () async {
    final roles = await agents.roles();
    await agents.create(
      employeeCode: 'bar01',
      firstName: 'Ines',
      lastName: 'Mbarga',
      pin: '4321',
      roleCode: roles.first.code,
    );
    final api = _FauxApi();

    await OutboxSender(db: db, api: api).drain();

    final (methode, chemin, corps) = api.appels.single;
    expect((methode, chemin), ('POST', '/users'));
    expect(corps['pin'], '4321');
    expect(corps['employee_code'], 'BAR01');
    // Le serveur l'a : la tablette n'en garde aucune copie.
    final restes = await db.select(db.outboxEntries).get();
    expect(
      restes.map((e) => (jsonDecode(e.payload) as Map).containsKey('pin')),
      everyElement(isFalse),
    );
    final u = await (db.select(db.users)
          ..where((u) => u.employeeCode.equals('BAR01')))
        .getSingle();
    expect(u.pinHash, isNull);
  });

  test('desactiver un agent part en PATCH sans rien effacer', () async {
    final roles = await agents.roles();
    final u = await agents.create(
      employeeCode: 'BAR01',
      firstName: 'Ines',
      lastName: 'Mbarga',
      pin: '4321',
      roleCode: roles.first.code,
    );
    await agents.update(
      id: u.id,
      firstName: 'Ines',
      lastName: 'Mbarga',
      isActive: false,
      roleCode: roles.first.code,
    );
    final api = _FauxApi();

    await OutboxSender(db: db, api: api).drain();

    final (methode, chemin, corps) = api.appels.last;
    expect((methode, chemin), ('PATCH', '/users/${u.id}'));
    expect(corps['is_active'], isFalse);
    expect(
      (await (db.select(db.users)..where((x) => x.id.equals(u.id))).get()),
      hasLength(1),
    );
  });

  test('refus avant ecriture : code pris, PIN mal forme', () async {
    final roles = await agents.roles();
    final avant = (await db.select(db.outboxEntries).get()).length;

    await expectLater(
      agents.create(
        employeeCode: 'RECEP01',
        firstName: 'A',
        lastName: 'B',
        pin: '4321',
        roleCode: roles.first.code,
      ),
      throwsStateError,
    );
    await expectLater(
      agents.create(
        employeeCode: 'BAR01',
        firstName: 'A',
        lastName: 'B',
        pin: '12',
        roleCode: roles.first.code,
      ),
      throwsStateError,
    );
    expect((await db.select(db.outboxEntries).get()).length, avant);
  });

  test('le barman ne voit que ses points de vente dans l\'ecran Commande',
      () async {
    final points = OutletRepository(db);
    final bar = await points.create(code: 'BAR', label: 'Bar');
    await points.create(code: 'RESTO', label: 'Restaurant');
    final barman = await agents.create(
      employeeCode: 'BAR01',
      firstName: 'Ines',
      lastName: 'Mbarga',
      pin: '4321',
      roleCode: roleCommandes,
      outletIds: [bar.id],
    );
    final commandes = OrderRepository(db);

    final pourLui = await commandes.watchOutlets(agentId: barman.id).first;
    final pourTous = await commandes.watchOutlets().first;

    expect(pourLui.map((o) => o.code), ['BAR']);
    expect(pourTous.map((o) => o.code), containsAll(['BAR', 'RESTO']));
  });
}
