/// Champs obligatoires a la creation d'un client, et modification d'une fiche.
///
/// La regle ne vaut qu'a la creation : un client ancien, sans telephone ni
/// piece, reste consultable **et** modifiable tel quel.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/features/guests/guest_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un serveur de papier : il note la methode, le chemin et le corps.
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
  group('creation', () {
    test('une creation sans telephone est refusee', () {
      final manquants = missingForCreation(
        firstName: 'Awa',
        lastName: 'Diallo',
        phone: '  ',
        documentType: IdDocumentType.ID_CARD,
        documentNumber: 'CM-123',
      );
      expect(manquants, ['telephone']);
    });

    test('le module Clients exige aussi la piece', () {
      final manquants = missingForCreation(
        firstName: 'Awa',
        lastName: 'Diallo',
        phone: '690000000',
      );
      expect(manquants, ['type de piece', 'numero de piece']);
    });

    test('la creation rapide a la reservation se passe de la piece', () {
      // Au telephone, on n'a pas la piece sous les yeux.
      expect(
        missingForCreation(
          firstName: 'Awa',
          lastName: 'Diallo',
          phone: '690000000',
          withDocument: false,
        ),
        isEmpty,
      );
      // Mais pas du telephone.
      expect(
        missingForCreation(
          firstName: 'Awa',
          lastName: 'Diallo',
          phone: '',
          withDocument: false,
        ),
        ['telephone'],
      );
    });

    test('une fiche complete passe', () {
      expect(
        missingForCreation(
          firstName: 'Awa',
          lastName: 'Diallo',
          phone: '690000000',
          documentType: IdDocumentType.PASSPORT,
          documentNumber: 'P-42',
        ),
        isEmpty,
      );
    });
  });

  group('client ancien et incomplet', () {
    late AtriumDatabase db;
    late GuestRepository guests;

    setUp(() async {
      db = AtriumDatabase.memory();
      await db.customStatement('PRAGMA foreign_keys = ON');
      await seedDemoData(db);
      guests = GuestRepository(db);
    });

    tearDown(() => db.close());

    /// Un client d'avant la regle : nom et prenom, rien d'autre.
    Future<GuestRow> ancien() =>
        guests.create(firstName: 'Amadou', lastName: 'Kone');

    test('reste consultable', () async {
      final g = await ancien();

      expect((await guests.byId(g.id))!.phone, isNull);
      final liste = await guests.watchGuests(search: 'Kone').first;
      expect(liste.map((x) => x.id), contains(g.id));
    });

    test('reste modifiable sans qu\'on exige ce qui lui manque', () async {
      final g = await ancien();

      final modifie = await guests.update(
        id: g.id,
        firstName: 'Amadou',
        lastName: 'Kone',
        nationality: 'Camerounaise',
      );

      expect(modifie.nationality, 'Camerounaise');
      expect(modifie.phone, isNull);
      expect(modifie.syncState, SyncState.pending);
    });

    test('nom et prenom restent exiges a la modification', () async {
      final g = await ancien();
      final avant = (await db.select(db.outboxEntries).get()).length;

      expect(
        () => guests.update(id: g.id, firstName: 'Amadou', lastName: ' '),
        throwsStateError,
      );
      expect((await db.select(db.outboxEntries).get()).length, avant);
    });

    test('la modification part en PATCH, vides compris', () async {
      final g = await guests.create(
        firstName: 'Awa',
        lastName: 'Diallo',
        phone: '690000000',
      );
      // Le telephone est retire : il doit s'effacer aussi sur le serveur.
      await guests.update(id: g.id, firstName: 'Awa', lastName: 'Diallo');

      final entree = (await db.select(db.outboxEntries).get()).last;
      expect(entree.op, SyncOp.UPDATE);
      expect((jsonDecode(entree.payload) as Map)['phone'], isNull);

      final api = _FauxApi();
      await OutboxSender(db: db, api: api).drain();

      expect(api.appels.first.$1, 'POST');
      final (methode, chemin, corps) = api.appels.last;
      expect(methode, 'PATCH');
      expect(chemin, '/guests/${g.id}');
      expect(corps.containsKey('phone'), isTrue);
      expect(corps['phone'], isNull);
      // Ce que l'ecran ne connait pas n'est pas envoye : le serveur le garde.
      expect(corps.containsKey('notes'), isFalse);
      expect(corps.containsKey('credit_limit'), isFalse);
    });
  });
}
