/// Une tablette revoquee d'un autre poste s'efface (correction 9).
///
/// Une tablette perdue ou volee gardait sa base : clients, ardoises,
/// empreintes des codes. Revoquee sur le serveur, elle recoit un 410 a son
/// prochain contact, et efface sa base, sa cle et ses jetons.
library;

import 'dart:io';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/effacement.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/auth_api.dart';
import 'package:atrium/data/remote/signalement_blocages.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/auth_repository.dart';
import 'package:atrium/data/repositories/blocages_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/schema_ancien.dart';

/// Le serveur d'authentification : revoque la tablette, ou l'accepte.
class _Auth extends AuthApi {
  _Auth({this.revoquee = true})
    : super(
        ApiClient(baseUrl: 'http://serveur.invalide', tokens: const TokenStore()),
        const TokenStore(),
      );

  final bool revoquee;
  String? tabletteVue;
  var jetonsOublies = false;

  @override
  Future<AuthSession> login({
    required String employeeCode,
    required String secret,
    String? tablette,
  }) async {
    tabletteVue = tablette;
    if (revoquee) {
      throw const ApiException(
        ApiFailure.revoked,
        'Cette tablette a ete revoquee.',
      );
    }
    throw const ApiException(ApiFailure.unauthorized, 'Code faux');
  }

  @override
  Future<void> oublierJetons() async => jetonsOublies = true;
}

/// Le serveur des tablettes : `PUT /devices/me` repond 410.
class _ServeurRevoque extends ApiClient {
  _ServeurRevoque()
    : super(baseUrl: 'http://serveur.invalide', tokens: const TokenStore());

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      throw const ApiException(ApiFailure.revoked, 'revoquee');
}

void main() {
  late AtriumDatabase db;
  var cleOubliee = false;
  var verifieLocalement = false;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    await GuestRepository(db).create(firstName: 'Awa', lastName: 'Kone');
    cleOubliee = false;
    verifieLocalement = false;
  });

  tearDown(() => db.close());

  Future<void> effacer(AtriumDatabase db) =>
      effacerLaBase(db, oublierCle: () async => cleOubliee = true);

  AuthRepository depot(_Auth auth) => AuthRepository(db, auth, (
    code,
    secret,
  ) async {
    verifieLocalement = true;
    return const LoginResult.failed(LoginFailure.wrongSecret);
  }, effacer);

  Future<int> lignes() async {
    var n = 0;
    for (final t in db.allTables) {
      n += (await db.select(t).get()).length;
    }
    return n;
  }

  test('effacer la base : toutes les tables, et la cle', () async {
    expect(await lignes(), greaterThan(0));

    await effacer(db);

    expect(await lignes(), 0);
    expect(cleOubliee, isTrue);
  });

  test('a la connexion : 410, la tablette s efface, sans repli local', () async {
    final auth = _Auth();
    final id = await db.identifiantTablette();

    final r = await depot(auth).login(employeeCode: 'RECEP01', secret: '123456');

    expect(auth.tabletteVue, id, reason: 'la connexion dit quelle tablette');
    expect(r.failure, LoginFailure.revokedDevice);
    expect(verifieLocalement, isFalse);
    expect(auth.jetonsOublies, isTrue);
    expect(await lignes(), 0);
    expect(cleOubliee, isTrue);
  });

  test('un code faux sur une tablette en regle n efface rien', () async {
    final r = await depot(
      _Auth(revoquee: false),
    ).login(employeeCode: 'RECEP01', secret: '000000');

    expect(r.failure, LoginFailure.wrongSecret);
    expect(await lignes(), greaterThan(0));
  });

  test('a la reprise en ligne aussi', () async {
    final r = await depot(
      _Auth(),
    ).reconnecter(employeeCode: 'RECEP01', secret: '123456');

    expect(r, Reprise.revoquee);
    expect(await lignes(), 0);
  });

  test('la presentation de la tablette apprend la revocation', () async {
    final s = SignalementBlocages(db: db, api: _ServeurRevoque());
    expect(await s.presenter(), isTrue);
  });

  test('la session se ferme sur l ecran de la revocation', () async {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authRepositoryProvider.overrideWithValue(depot(_Auth())),
      ],
    );
    addTearDown(c.dispose);

    final ok = await c
        .read(sessionProvider.notifier)
        .connecter(codeAgent: 'RECEP01', secret: '123456');

    expect(ok, isFalse);
    expect(c.read(sessionProvider).revoquee, isTrue);
    expect(c.read(sessionProvider).estConnecte, isFalse);
  });

  test('la revocation descend avec la fiche de la tablette', () {
    final t = tabletteDuServeur(
      {
        'id': '01920000-0000-7000-8000-00000000cd34',
        'name': 'Bar',
        'is_active': false,
        'updated_at': '2026-10-28T08:00:00Z',
        'revoked_at': '2026-10-28T08:00:00Z',
        'revoked_by': '01920000-0000-7000-8000-000000050001',
        'revocation_reason': 'Volee',
      },
      hotelId: '01920000-0000-7000-8000-000000000001',
      maintenant: DateTime.utc(2026, 10, 28),
    );
    expect(t.revokedAt.value, DateTime.utc(2026, 10, 28, 8));
    expect(t.revocationReason.value, 'Volee');
  });

  test(
    'une tablette deployee recoit les colonnes de la revocation',
    () async {
      final dossier = Directory.systemTemp.createTempSync('atrium_revoc');
      addTearDown(() => dossier.deleteSync(recursive: true));
      final fichier = File('${dossier.path}/atrium.sqlite');

      var base = AtriumDatabase(NativeDatabase(fichier));
      await base.customSelect('SELECT 1').get();
      await retirerColonnesApres(base, 20);
      await base.customStatement('PRAGMA user_version = 20');
      await base.close();

      base = AtriumDatabase(NativeDatabase(fichier));
      final colonnes = await base
          .customSelect("SELECT name FROM pragma_table_info('devices')")
          .map((r) => r.read<String>('name'))
          .get();
      expect(
        colonnes,
        containsAll(['revoked_at', 'revoked_by', 'revocation_reason']),
      );
      await base.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
