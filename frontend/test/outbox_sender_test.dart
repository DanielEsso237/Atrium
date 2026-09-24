/// Le moteur qui vide la file d'envoi.
///
/// Ces tests portent sur les trois choses qui font mal en vrai : une entree
/// traduite de travers part en 422 et bloque la file ; une entree envoyee
/// dans le desordre arrive avant ce dont elle depend ; une coupure reseau au
/// mauvais moment fait perdre une ecriture.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ce qui est parti sur le reseau.
class _Appel {
  const _Appel(this.chemin, this.corps);
  final String chemin;
  final Map<String, Object?> corps;
}

/// Un serveur de papier : il note ce qu'on lui envoie et repond ce qu'on lui
/// a dit de repondre.
class _FauxApi extends ApiClient {
  _FauxApi({this.echec})
    : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final ApiException? echec;
  final appels = <_Appel>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    appels.add(_Appel(path, (body as Map?)?.cast<String, Object?>() ?? {}));
    if (echec != null) throw echec!;
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late GuestRepository guests;
  late ReservationRepository reservations;

  final typeStandard = roomTypeSeeds.first.id;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    guests = GuestRepository(db);
    reservations = ReservationRepository(db);
  });

  tearDown(() => db.close());

  Future<int> enAttente() async {
    final r = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM outbox_entries "
          "WHERE status IN ('PENDING','FAILED')",
        )
        .getSingle();
    return r.read<int>('n');
  }

  Future<String> creerClient() async {
    final g = await guests.create(firstName: 'Amadou', lastName: 'Kone');
    return g.id;
  }

  test('un client remonte, la file se vide, la ligne passe synced', () async {
    final id = await creerClient();
    final api = _FauxApi();

    final rapport = await OutboxSender(db: db, api: api).drain();

    expect(rapport.arret, DrainStop.termine);
    expect(rapport.envoyees, 1);
    expect(await enAttente(), 0);

    expect(api.appels.single.chemin, '/guests');
    expect(api.appels.single.corps['id'], id);
    expect(api.appels.single.corps['first_name'], 'Amadou');

    final ligne = await guests.byId(id);
    expect(ligne!.syncState, SyncState.synced);
  });

  test('aucun chemin ne reecrit le prefixe deja pose par le client', () async {
    // Vecu : le moteur prefixait `/api/v1` alors que le `baseUrl` du client
    // le portait deja. Resultat, `/api/v1/api/v1/guests`, un 404 sur la
    // premiere entree, et toute la file bloquee derriere elle.
    final guestId = await creerClient();
    await reservations.create(
      guestId: guestId,
      roomTypeId: typeStandard,
      arrival: DateTime.utc(2026, 9, 20),
      departure: DateTime.utc(2026, 9, 22),
      nightlyRate: 25000,
    );

    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();

    expect(api.appels, isNotEmpty);
    for (final appel in api.appels) {
      expect(
        appel.chemin,
        isNot(contains('/api/v1')),
        reason: 'le prefixe vient du baseUrl, pas du moteur',
      );
      expect(appel.chemin, startsWith('/'));
    }
  });

  test('le hotel_id local ne part pas : le serveur le deduit du jeton', () async {
    await creerClient();
    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();

    // `code` non plus : c'est le serveur qui numerote, sinon deux tablettes
    // hors ligne attribueraient le meme CLI-00001.
    expect(api.appels.single.corps.containsKey('hotel_id'), isFalse);
    expect(api.appels.single.corps.containsKey('code'), isFalse);
  });

  test('une reservation part avec les dates sur chaque ligne', () async {
    // Le contrat rend `arrival_date` et `departure_date` obligatoires sur
    // chaque ligne de chambre, alors qu'elles vivent sur le dossier cote
    // tablette. Sans la recopie, toute reservation repartait en 422 et
    // bloquait la file derriere elle.
    final guestId = await creerClient();
    await reservations.create(
      guestId: guestId,
      roomTypeId: typeStandard,
      arrival: DateTime.utc(2026, 9, 20),
      departure: DateTime.utc(2026, 9, 22),
      nightlyRate: 25000,
    );

    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();

    final reservation = api.appels.last;
    expect(reservation.chemin, '/reservations');

    final lignes = reservation.corps['rooms'] as List;
    final ligne = lignes.single as Map<String, Object?>;
    expect(ligne['arrival_date'], '2026-09-20');
    expect(ligne['departure_date'], '2026-09-22');
    expect(ligne['room_type_id'], typeStandard);
  });

  test('le client part avant la reservation qui le designe', () async {
    final guestId = await creerClient();
    await reservations.create(
      guestId: guestId,
      roomTypeId: typeStandard,
      arrival: DateTime.utc(2026, 9, 20),
      departure: DateTime.utc(2026, 9, 22),
      nightlyRate: 25000,
    );

    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();

    expect(
      api.appels.map((a) => a.chemin),
      ['/guests', '/reservations'],
    );
  });

  test('hors ligne : rien n\'est acquitte, la file reste entiere', () async {
    await creerClient();
    final api = _FauxApi(
      echec: const ApiException(ApiFailure.offline, 'injoignable'),
    );

    final rapport = await OutboxSender(db: db, api: api).drain();

    expect(rapport.arret, DrainStop.horsLigne);
    expect(rapport.envoyees, 0);
    expect(await enAttente(), 1);

    // L'entree reste PENDING : elle n'a rien fait de mal, c'est le couloir.
    final e = await db.select(db.outboxEntries).getSingle();
    expect(e.status, OutboxStatus.PENDING);
    expect(e.attempts, 1);
  });

  test('un refus de fond bloque la file au lieu de la sauter', () async {
    await creerClient();
    await creerClient();

    final api = _FauxApi(
      echec: const ApiException(ApiFailure.invalid, 'champ manquant'),
    );
    final rapport = await OutboxSender(db: db, api: api).drain();

    expect(rapport.arret, DrainStop.bloque);
    expect(rapport.detail, 'champ manquant');

    // Une seule tentative : la seconde entree n'a pas ete essayee. Sauter
    // l'entree fautive enverrait la suite dans un etat que personne n'a voulu.
    expect(api.appels.length, 1);
    expect(await enAttente(), 2);

    final premiere = await (db.select(
      db.outboxEntries,
    )..limit(1)).getSingle();
    expect(premiere.status, OutboxStatus.FAILED);
    expect(premiere.lastError, 'champ manquant');
  });

  test('renvoyer apres un acquittement perdu ne renvoie rien', () async {
    await creerClient();
    final api = _FauxApi();

    await OutboxSender(db: db, api: api).drain();
    final second = await OutboxSender(db: db, api: api).drain();

    expect(second.envoyees, 0);
    expect(second.arret, DrainStop.termine);
    expect(api.appels.length, 1);
  });
}
