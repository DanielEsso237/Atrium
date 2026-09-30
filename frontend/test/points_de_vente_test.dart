/// Les points de vente, depuis l'administration.
///
/// Jamais supprimes : desactives, ils sortent des onglets de l'ecran Commande
/// et restent ici, prets a etre reactives -- les commandes passees y
/// renvoient.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
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
  late OutletRepository points;
  late OrderRepository commandes;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    points = OutletRepository(db);
    commandes = OrderRepository(db);
  });

  tearDown(() => db.close());

  test('desactiver un point de vente le retire des onglets', () async {
    final bar = await points.create(code: 'BAR', label: 'Bar');
    await points.create(code: 'RESTO', label: 'Restaurant');

    await points.update(
      id: bar.id,
      code: 'BAR',
      label: 'Bar',
      allowsRoomCharge: true,
      sortOrder: 0,
      isActive: false,
    );

    final onglets = await commandes.watchOutlets().first;
    expect(onglets.map((o) => o.code), isNot(contains('BAR')));
    expect(onglets.map((o) => o.code), contains('RESTO'));
    // Toujours la, pret a etre reactive.
    final tous = await points.watchAll().first;
    expect(tous.map((o) => o.code), contains('BAR'));
  });

  test('creation en POST, desactivation en PATCH', () async {
    final bar = await points.create(
      code: 'BAR',
      label: 'Bar',
      opensAt: '18:00',
      closesAt: '02:00',
    );
    await points.update(
      id: bar.id,
      code: 'BAR',
      label: 'Bar',
      opensAt: '18:00',
      allowsRoomCharge: false,
      sortOrder: 2,
      isActive: false,
    );
    final api = _FauxApi();

    await OutboxSender(db: db, api: api).drain();

    expect(api.appels.first.$1, 'POST');
    expect(api.appels.first.$3['id'], bar.id);
    final (methode, chemin, corps) = api.appels.last;
    expect((methode, chemin), ('PATCH', '/outlets/${bar.id}'));
    expect(corps['is_active'], isFalse);
    // L'horaire de fermeture retire l'est aussi sur le serveur.
    expect(corps.containsKey('closes_at'), isTrue);
    expect(corps['closes_at'], isNull);
  });

  test("le Restaurant par defaut ne se desactive pas et garde son code",
      () async {
    final resto = await points.create(code: defaultOutletCode, label: 'Restaurant');
    final avant = (await db.select(db.outboxEntries).get()).length;

    await expectLater(
      points.update(
        id: resto.id,
        code: defaultOutletCode,
        label: 'Restaurant',
        allowsRoomCharge: true,
        sortOrder: 0,
        isActive: false,
      ),
      throwsStateError,
    );
    await expectLater(
      points.update(
        id: resto.id,
        code: 'CUISINE',
        label: 'Restaurant',
        allowsRoomCharge: true,
        sortOrder: 0,
        isActive: true,
      ),
      throwsStateError,
    );
    expect((await db.select(db.outboxEntries).get()).length, avant);

    // Son libelle, lui, reste libre.
    await points.update(
      id: resto.id,
      code: defaultOutletCode,
      label: 'La Terrasse',
      allowsRoomCharge: true,
      sortOrder: 0,
      isActive: true,
    );
  });

  test("le code se deduit du libelle, unique", () async {
    final a = await points.create(label: 'Boîte de nuit');
    final b = await points.create(label: 'Boite de Nuit');

    expect(a.code, 'BOITE_DE_NUIT');
    expect(b.code, 'BOITE_DE_NUIT_2');
    expect(codeDepuisLibelle('  '), 'PDV');
  });

  test("glisser-deposer renvoie seulement ce qui a bouge", () async {
    final a = await points.create(label: 'A');
    final b = await points.create(label: 'B');
    final c = await points.create(label: 'C');
    final avant = (await db.select(db.outboxEntries).get()).length;

    await points.reorder([c.id, a.id, b.id]);

    final ordre = await points.watchAll().first;
    expect(ordre.map((o) => o.label).where((l) => l.length == 1), ['C', 'A', 'B']);
    expect((await db.select(db.outboxEntries).get()).length - avant, 3);
  });

  test('refus avant ecriture : code pris, horaire mal forme', () async {
    await points.create(code: 'BAR', label: 'Bar');
    final avant = (await db.select(db.outboxEntries).get()).length;

    await expectLater(
      points.create(code: 'BAR', label: 'Autre bar'),
      throwsStateError,
    );
    await expectLater(
      points.create(code: 'PISCINE', label: 'Piscine', opensAt: '25:00'),
      throwsStateError,
    );
    expect((await db.select(db.outboxEntries).get()).length, avant);
  });
}
