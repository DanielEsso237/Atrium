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
}
