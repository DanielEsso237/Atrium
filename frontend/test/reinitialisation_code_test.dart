// Code oublie : un responsable le reinitialise sur place (21 octobre), et
// cinq codes faux bloquent un agent -- les memes regles que le serveur
// (`backend/tests/test_reinitialisation_code.py`).

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/auth_api.dart';
import 'package:atrium/data/repositories/agent_repository.dart';
import 'package:atrium/data/repositories/reinitialisation_repository.dart';
import 'package:atrium/features/auth/auth_locale.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

/// Le serveur : injoignable, ou qui accepte et note ce qu'il recoit.
class _Serveur implements AuthApi {
  _Serveur({this.enLigne = false});

  bool enLigne;
  final recus = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> resetSecret(Map<String, Object?> corps) async {
    if (!enLigne) throw const ApiException(ApiFailure.offline, 'hors ligne');
    recus.add(corps);
    return {'user_id': 'x', 'approved_by': 'y'};
  }

  /// Ce que le serveur repond a un changement de PIN, s'il refuse.
  ApiException? refusChangement;
  final changements = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> changePin(Map<String, Object?> corps) async {
    if (!enLigne) throw const ApiException(ApiFailure.offline, 'hors ligne');
    if (refusChangement != null) throw refusChangement!;
    changements.add(corps);
    return {'user_id': 'x'};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AtriumDatabase db;
  late AuthLocale auth;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedAccounts(db);
    auth = AuthLocale(db);
  });

  tearDown(() => db.close());

  Future<UserRow> agent(String code) async =>
      (await agentParCode(db, code))!;

  Future<EchecConnexion?> connexion(String code, String secret) async =>
      (await auth.connecter(codeAgent: code, secret: secret)).echec;

  test("une empreinte bcrypt du serveur ouvre la session hors ligne", () async {
    final recep = await agent('RECEP01');
    await (db.update(db.users)..where((u) => u.id.equals(recep.id))).write(
      UsersCompanion(
        pinHash: Value(BCrypt.hashpw('2468', BCrypt.gensalt(logRounds: 4))),
      ),
    );

    expect(await connexion('recep01', '2468'), isNull);
    expect(await connexion('RECEP01', '1234'), EchecConnexion.secretInvalide);
    // Ce qu'on ne sait pas verifier ne passe pas.
    expect(await AuthLocale.verifierSecret('x', 'md5:abc'), isFalse);
  });

  test("cinq codes faux bloquent l'agent, meme avec le bon ensuite", () async {
    for (var i = 0; i < 5; i++) {
      expect(await connexion('RECEP01', '0000'), EchecConnexion.secretInvalide);
    }
    expect(await connexion('RECEP01', pinDemo), EchecConnexion.compteBloque);
    // Attendre ne suffit pas.
    await (db.update(db.users)..where((u) => u.employeeCode.equals('RECEP01')))
        .write(
          UsersCompanion(
            lockedUntil: Value(
              DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            ),
          ),
        );
    expect(await connexion('RECEP01', pinDemo), EchecConnexion.compteBloque);
  });

  test("un responsable bloque attend un quart d'heure", () async {
    for (var i = 0; i < 5; i++) {
      await connexion('ADMIN01', '0000');
    }
    expect(await connexion('ADMIN01', pinDemo), EchecConnexion.compteBloque);
    final admin = await agent('ADMIN01');
    expect(admin.lockedUntil, isNotNull);

    await (db.update(db.users)..where((u) => u.id.equals(admin.id))).write(
      UsersCompanion(
        lockedUntil: Value(
          DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
        ),
      ),
    );
    expect(await connexion('ADMIN01', pinDemo), isNull);
    expect((await agent('ADMIN01')).failedLoginCount, 0);
  });

  test('hors ligne : le nouveau code vaut aussitot, et part par la file', () async {
    for (var i = 0; i < 5; i++) {
      await connexion('RECEP01', '0000');
    }
    await ReinitialisationRepository(db, _Serveur()).reinitialiser(
      codeAgent: 'recep01',
      codeResponsable: 'ADMIN01',
      secretResponsable: pinDemo,
      nouveauPin: '567890',
      nouveauMotDePasse: 'Nouveau123',
    );

    expect(await connexion('RECEP01', '567890'), isNull);
    expect(await connexion('RECEP01', 'Nouveau123'), isNull);
    expect(await connexion('RECEP01', pinDemo), EchecConnexion.secretInvalide);
    expect((await agent('RECEP01')).syncState, SyncState.pending);

    final entree = await db.select(db.outboxEntries).getSingle();
    final p = jsonDecode(entree.payload) as Map<String, dynamic>;
    expect(p['action'], actionReinitialiser);
    expect(p['employee_code'], 'RECEP01');
    expect(p['approver_code'], 'ADMIN01');
  });

  test('les refus avant toute ecriture', () async {
    final repo = ReinitialisationRepository(db, _Serveur());
    Future<void> essai({
      String agent = 'MENAGE01',
      String responsable = 'ADMIN01',
      String secret = pinDemo,
      String? pin = '567890',
    }) => repo.reinitialiser(
      codeAgent: agent,
      codeResponsable: responsable,
      secretResponsable: secret,
      nouveauPin: pin,
    );

    // La reception n'a pas le droit de reinitialiser.
    await expectLater(essai(responsable: 'RECEP01'), throwsStateError);
    await expectLater(essai(secret: '0000'), throwsStateError);
    expect((await agent('ADMIN01')).failedLoginCount, 1);
    await expectLater(essai(agent: 'ADMIN01'), throwsStateError);
    await expectLater(essai(pin: '12'), throwsStateError);
    await expectLater(essai(pin: null), throwsStateError);
    expect(await db.select(db.outboxEntries).get(), isEmpty);
    expect(await connexion('MENAGE01', pinDemo), isNull);
  });

  test("en ligne : le serveur juge, rien n'est enfile", () async {
    final serveur = _Serveur(enLigne: true);
    await ReinitialisationRepository(db, serveur).reinitialiser(
      codeAgent: 'RECEP01',
      codeResponsable: 'ADMIN01',
      secretResponsable: pinDemo,
      nouveauPin: '567890',
    );

    expect(serveur.recus.single['new_pin'], '567890');
    expect(serveur.recus.single.containsKey('new_password'), isFalse);
    expect(await db.select(db.outboxEntries).get(), isEmpty);
    expect(await connexion('RECEP01', '567890'), isNull);
    expect((await agent('RECEP01')).syncState, SyncState.synced);
  });

  test(
    'avant la connexion en ligne, la reinitialisation remonte et ses secrets '
    "s'effacent",
    () async {
      final serveur = _Serveur();
      final repo = ReinitialisationRepository(db, serveur);
      await repo.reinitialiser(
        codeAgent: 'RECEP01',
        codeResponsable: 'ADMIN01',
        secretResponsable: pinDemo,
        nouveauPin: '567890',
      );

      // Toujours hors ligne : l'entree attend.
      await repo.remonterEnAttente('RECEP01');
      expect(
        (await db.select(db.outboxEntries).getSingle()).status,
        OutboxStatus.PENDING,
      );

      serveur.enLigne = true;
      await repo.remonterEnAttente('recep01');

      expect(serveur.recus.single, {
        'employee_code': 'RECEP01',
        'approver_code': 'ADMIN01',
        'approver_secret': pinDemo,
        'new_pin': '567890',
      });
      final entree = await db.select(db.outboxEntries).getSingle();
      expect(entree.status, OutboxStatus.ACKED);
      final p = jsonDecode(entree.payload) as Map<String, dynamic>;
      expect(p.containsKey('approver_secret'), isFalse);
      expect(p.containsKey('new_pin'), isFalse);
      expect((await agent('RECEP01')).syncState, SyncState.synced);
    },
  );

  test("la descente n'ecrase pas un code qui attend de remonter", () async {
    await ReinitialisationRepository(db, _Serveur()).reinitialiser(
      codeAgent: 'RECEP01',
      codeResponsable: 'ADMIN01',
      secretResponsable: pinDemo,
      nouveauPin: '567890',
    );
    final recep = await agent('RECEP01');
    final depot = AgentRepository(db);
    Map<String, dynamic> serveur(String id, String code) => {
      'id': id,
      'employee_code': code,
      'first_name': 'X',
      'last_name': code,
      'is_active': true,
      'roles': const [],
      'pin_hash': BCrypt.hashpw('9999', BCrypt.gensalt(logRounds: 4)),
      'password_hash': null,
      'failed_login_count': 0,
      'locked_until': null,
    };

    await depot.applyServerCredentials(serveur(recep.id, 'RECEP01'));
    expect(await connexion('RECEP01', '567890'), isNull);

    // Un agent sans ecriture en attente prend l'empreinte du serveur.
    final menage = await agent('MENAGE01');
    await depot.applyServerCredentials(serveur(menage.id, 'MENAGE01'));
    expect(await connexion('MENAGE01', '9999'), isNull);
    expect(await connexion('MENAGE01', pinDemo), EchecConnexion.secretInvalide);
  });

  // Le PIN passe a 6 chiffres (25 octobre) : l'agent connecte avec son
  // ancien code en choisit un nouveau, en ligne comme hors ligne.
  group('passer a 6 chiffres', () {
    test('en ligne : le serveur change, la tablette recopie', () async {
      final serveur = _Serveur(enLigne: true);
      await ReinitialisationRepository(
        db,
        serveur,
      ).changerPin(codeAgent: 'recep01', ancien: '1234', nouveau: '135790');

      expect(serveur.changements.single, {
        'employee_code': 'RECEP01',
        'current_secret': '1234',
        'new_pin': '135790',
      });
      expect(await db.select(db.outboxEntries).get(), isEmpty);
      expect(await connexion('RECEP01', '135790'), isNull);
      expect((await agent('RECEP01')).syncState, SyncState.synced);
    });

    test('hors ligne : le code vaut aussitot et remonte avant la connexion',
        () async {
      final serveur = _Serveur();
      final repo = ReinitialisationRepository(db, serveur);
      await repo.changerPin(
        codeAgent: 'RECEP01',
        ancien: '1234',
        nouveau: '135790',
      );

      expect(await connexion('RECEP01', '135790'), isNull);
      expect((await agent('RECEP01')).syncState, SyncState.pending);
      var entree = await db.select(db.outboxEntries).getSingle();
      expect(jsonDecode(entree.payload)['action'], actionChangerPin);

      serveur.enLigne = true;
      await repo.remonterEnAttente('RECEP01');

      expect(serveur.changements.single['new_pin'], '135790');
      entree = await db.select(db.outboxEntries).getSingle();
      expect(entree.status, OutboxStatus.ACKED);
      final p = jsonDecode(entree.payload) as Map<String, dynamic>;
      expect(p.containsKey('current_secret'), isFalse);
      expect(p.containsKey('new_pin'), isFalse);
    });

    test('un code qui ne fait pas 6 chiffres est refuse avant tout', () async {
      final repo = ReinitialisationRepository(db, _Serveur(enLigne: true));
      for (final nouveau in ['1234', '12345', '1234567', 'abcdef']) {
        await expectLater(
          repo.changerPin(codeAgent: 'RECEP01', ancien: '1234', nouveau: nouveau),
          throwsStateError,
        );
      }
      expect(await db.select(db.outboxEntries).get(), isEmpty);
    });

    test('un refus du serveur ne change rien', () async {
      final serveur = _Serveur(enLigne: true)
        ..refusChangement = const ApiException(
          ApiFailure.forbidden,
          'Code actuel incorrect.',
        );
      await expectLater(
        ReinitialisationRepository(
          db,
          serveur,
        ).changerPin(codeAgent: 'RECEP01', ancien: '0000', nouveau: '135790'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Code actuel incorrect.',
          ),
        ),
      );
      expect(await connexion('RECEP01', '135790'), EchecConnexion.secretInvalide);
      expect(await db.select(db.outboxEntries).get(), isEmpty);
    });
  });
}
