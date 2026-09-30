/// Le plafond d'un client, fixe depuis l'administration.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/features/administration/credit_limits_section.dart';
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
  late GuestRepository guests;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    guests = GuestRepository(db);
  });

  tearDown(() => db.close());

  test('le plafond part seul, sans toucher a la fiche', () async {
    final g = await guests.create(
      firstName: 'Awa',
      lastName: 'Diallo',
      phone: '690000000',
    );

    await guests.setCreditLimit(id: g.id, creditLimit: 50000);

    expect((await guests.byId(g.id))!.creditLimit, 50000);
    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();
    final (methode, chemin, corps) = api.appels.last;
    expect((methode, chemin), ('PATCH', '/guests/${g.id}'));
    expect(corps, {
      'first_name': 'Awa',
      'last_name': 'Diallo',
      'credit_limit': 50000,
    });
  });

  test('un plafond negatif est refuse avant d\'ecrire', () async {
    final g = await guests.create(firstName: 'Awa', lastName: 'Diallo');
    final avant = (await db.select(db.outboxEntries).get()).length;

    await expectLater(
      guests.setCreditLimit(id: g.id, creditLimit: -1),
      throwsStateError,
    );
    expect((await db.select(db.outboxEntries).get()).length, avant);
  });

  test('zero se lit « pas de limite »', () {
    expect(libellePlafond(0), 'Pas de limite');
    expect(libellePlafond(50000), isNot('Pas de limite'));
  });
}
