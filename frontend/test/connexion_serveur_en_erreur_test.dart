/// Un serveur en panne n'est pas un mauvais code.
///
/// Vecu pendant les essais sur tablette : un tunnel ferme repondait 404, et
/// l'ecran disait « Code incorrect » a un agent qui tapait le bon PIN. Seuls
/// les refus du serveur sur l'agent lui-meme (401, 403, 423) sont des refus ;
/// le reste se traite comme un serveur injoignable.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/auth_api.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un serveur qui repond toujours par le meme echec.
class _ServeurQuiEchoue extends AuthApi {
  _ServeurQuiEchoue(this.echec)
    : super(
        ApiClient(baseUrl: 'http://serveur.invalide', tokens: const TokenStore()),
        const TokenStore(),
      );

  final ApiFailure echec;

  @override
  Future<AuthSession> login({
    required String employeeCode,
    required String secret,
  }) async => throw ApiException(echec, 'echec simule');
}

/// Un serveur revenu, qui accepte l'agent.
class _ServeurRevenu extends AuthApi {
  _ServeurRevenu()
    : super(
        ApiClient(baseUrl: 'http://serveur.invalide', tokens: const TokenStore()),
        const TokenStore(),
      );

  @override
  Future<AuthSession> login({
    required String employeeCode,
    required String secret,
  }) async => const AuthSession(
    accessToken: 'a',
    refreshToken: 'r',
    expiresIn: 3600,
    userId: '01920000-0000-7000-8000-00000000c001',
  );
}

void main() {
  late AtriumDatabase db;
  var verifieLocalement = false;

  setUp(() {
    db = AtriumDatabase.memory();
    verifieLocalement = false;
  });

  tearDown(() => db.close());

  Future<LoginResult> connecter(ApiFailure echec) => AuthRepository(
    db,
    _ServeurQuiEchoue(echec),
    (code, secret) async {
      verifieLocalement = true;
      return const LoginResult.failed(LoginFailure.offlineAndUnknown);
    },
  ).login(employeeCode: 'ADMIN01', secret: '1234');

  for (final echec in [
    ApiFailure.offline,
    ApiFailure.server,
    ApiFailure.notFound,
    ApiFailure.invalid,
  ]) {
    test('${echec.name} : la tablette verifie elle-meme', () async {
      await connecter(echec);
      expect(verifieLocalement, isTrue);
    });
  }

  test('401 : le serveur a refuse le code, on ne repasse pas derriere',
      () async {
    final r = await connecter(ApiFailure.unauthorized);
    expect(r.failure, LoginFailure.wrongSecret);
    expect(verifieLocalement, isFalse);
  });

  test('423 : compte verrouille', () async {
    expect((await connecter(ApiFailure.locked)).failure, LoginFailure.locked);
    expect(verifieLocalement, isFalse);
  });

  group('reprise en ligne apres une connexion hors ligne', () {
    Future<Reprise> reprendre(AuthApi api) => AuthRepository(
      db,
      api,
      (code, secret) async {
        verifieLocalement = true;
        return const LoginResult.failed(LoginFailure.offlineAndUnknown);
      },
    ).reconnecter(employeeCode: 'ADMIN01', secret: '1234');

    test('serveur toujours absent : on retentera, sans verifier en local',
        () async {
      expect(
        await reprendre(_ServeurQuiEchoue(ApiFailure.offline)),
        Reprise.injoignable,
      );
      expect(verifieLocalement, isFalse);
    });

    for (final refus in [
      ApiFailure.unauthorized,
      ApiFailure.forbidden,
      ApiFailure.locked,
    ]) {
      test('${refus.name} : on cesse, pour ne pas verrouiller le compte',
          () async {
        expect(await reprendre(_ServeurQuiEchoue(refus)), Reprise.refusee);
      });
    }

    test('serveur revenu : en ligne, et l agent est recopie', () async {
      expect(await reprendre(_ServeurRevenu()), Reprise.enLigne);
      expect(await db.select(db.users).get(), hasLength(1));
    });
  });
}
