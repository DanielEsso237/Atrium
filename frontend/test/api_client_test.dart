/// Traduction des codes HTTP en ApiFailure, avec un faux Dio (aucune requete
/// reseau reelle).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renvoie une reponse ou leve une DioException choisies a l'avance, sans
/// jamais toucher au reseau.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.statusCode, this.body = const {}, this.throwType});

  final int? statusCode;
  final Map<String, dynamic> body;
  final DioExceptionType? throwType;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (throwType != null) {
      throw DioException(requestOptions: options, type: throwType!);
    }
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(body)),
      statusCode!,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _clientReturning({
  required int statusCode,
  Map<String, dynamic> body = const {},
}) {
  final dio = Dio()
    ..httpClientAdapter = _FakeAdapter(statusCode: statusCode, body: body);
  return ApiClient(
    baseUrl: 'https://exemple.test',
    tokens: const TokenStore(),
    dio: dio,
  );
}

ApiClient _clientOffline() {
  final dio = Dio()
    ..httpClientAdapter = _FakeAdapter(
      throwType: DioExceptionType.connectionError,
    );
  return ApiClient(
    baseUrl: 'https://exemple.test',
    tokens: const TokenStore(),
    dio: dio,
  );
}

void main() {
  test('une erreur de connexion devient ApiFailure.offline', () async {
    final client = _clientOffline();

    await expectLater(
      client.get('/rooms'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.failure, 'failure', ApiFailure.offline)
            .having((e) => e.isOffline, 'isOffline', true),
      ),
    );
  });

  test('401 devient ApiFailure.unauthorized', () async {
    // Sans jeton de rafraichissement en magasin (TokenStore reelle, mais
    // sans plugin de stockage disponible en test), le rafraichissement
    // echoue silencieusement et l'echec 401 d'origine remonte tel quel.
    final client = _clientReturning(
      statusCode: 401,
      body: {'detail': 'Session expiree.'},
    );

    await expectLater(
      client.get('/rooms'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.failure, 'failure', ApiFailure.unauthorized)
            .having((e) => e.message, 'message', 'Session expiree.'),
      ),
    );
  });

  test('403 devient ApiFailure.forbidden', () async {
    final client = _clientReturning(
      statusCode: 403,
      body: {'detail': 'Droit manquant.'},
    );

    await expectLater(
      client.get('/rooms'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.failure,
          'failure',
          ApiFailure.forbidden,
        ),
      ),
    );
  });

  test('423 devient ApiFailure.locked', () async {
    final client = _clientReturning(
      statusCode: 423,
      body: {'detail': 'Compte verrouille.'},
    );

    await expectLater(
      client.get('/rooms'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.failure,
          'failure',
          ApiFailure.locked,
        ),
      ),
    );
  });

  test('404 devient ApiFailure.notFound', () async {
    final client = _clientReturning(
      statusCode: 404,
      body: {'detail': 'Chambre introuvable.'},
    );

    await expectLater(
      client.get('/rooms/x'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.failure,
          'failure',
          ApiFailure.notFound,
        ),
      ),
    );
  });

  test('409 devient ApiFailure.conflict', () async {
    final client = _clientReturning(
      statusCode: 409,
      body: {'detail': 'Arrivee deja enregistree.'},
    );

    await expectLater(
      client.post('/reservations/x/check-in'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.failure,
          'failure',
          ApiFailure.conflict,
        ),
      ),
    );
  });

  test('422 devient ApiFailure.invalid, avec le champ en cause', () async {
    final client = _clientReturning(
      statusCode: 422,
      body: {
        'detail': [
          {
            'loc': ['body', 'first_name'],
            'msg': 'Champ requis.',
            'type': 'missing',
          },
        ],
      },
    );

    await expectLater(
      client.post('/guests'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.failure, 'failure', ApiFailure.invalid)
            .having(
              (e) => e.message,
              'message',
              'body.first_name : Champ requis.',
            ),
      ),
    );
  });

  test('500 devient ApiFailure.server', () async {
    final client = _clientReturning(statusCode: 500);

    await expectLater(
      client.get('/rooms'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.failure,
          'failure',
          ApiFailure.server,
        ),
      ),
    );
  });

  test('un succes 2xx ne leve rien et renvoie les donnees', () async {
    final client = _clientReturning(
      statusCode: 200,
      body: {'id': 'abc', 'number': '101'},
    );

    final data = await client.get('/rooms/abc');
    expect(data['number'], '101');
  });

  test('chaque requete dit a ngrok de ne pas intercaler sa page', () async {
    final adaptateur = _EnTetesVus();
    final client = ApiClient(
      baseUrl: 'https://exemple.test',
      tokens: const TokenStore(),
      dio: Dio()..httpClientAdapter = adaptateur,
    );
    await client.get('/rooms');
    expect(adaptateur.enTetes['ngrok-skip-browser-warning'], '1');
  });

  group('le jeton se renouvelle avant d expirer', () {
    const tokens = TokenStore();
    tearDown(tokens.clear);

    test('expireBientot lit la date du jeton', () {
      final maintenant = DateTime.utc(2026, 10, 10, 12);
      expect(
        ApiClient.expireBientot(
          _jeton(maintenant.add(const Duration(minutes: 30))),
          maintenant,
        ),
        isFalse,
      );
      expect(
        ApiClient.expireBientot(
          _jeton(maintenant.add(const Duration(seconds: 30))),
          maintenant,
        ),
        isTrue,
      );
      expect(ApiClient.expireBientot('illisible', maintenant), isFalse);
    });

    test('un jeton qui expire part renouvele, sans passer par un 401',
        () async {
      final vieux = _jeton(DateTime.now().add(const Duration(seconds: 30)));
      final neuf = _jeton(DateTime.now().add(const Duration(hours: 1)));
      await tokens.save(accessToken: vieux, refreshToken: 'r1');
      final serveur = _Serveur(neuf);
      final client = ApiClient(
        baseUrl: 'https://exemple.test',
        tokens: tokens,
        dio: Dio()..httpClientAdapter = serveur,
      );

      await client.post('/housekeeping-tasks', body: const {});

      expect(serveur.vues.map((v) => v.$1), ['/auth/refresh', '/housekeeping-tasks']);
      expect(serveur.vues.last.$2, 'Bearer $neuf');
      expect(await tokens.readRefresh(), 'r2');
    });

    test('un jeton encore valide part tel quel', () async {
      final bon = _jeton(DateTime.now().add(const Duration(minutes: 30)));
      await tokens.save(accessToken: bon, refreshToken: 'r1');
      final serveur = _Serveur('jamais');
      final client = ApiClient(
        baseUrl: 'https://exemple.test',
        tokens: tokens,
        dio: Dio()..httpClientAdapter = serveur,
      );

      await client.get('/rooms');

      expect(serveur.vues.single, ('/rooms', 'Bearer $bon'));
    });
  });
}

/// Un faux jeton JWT dont seule la date d'expiration compte.
String _jeton(DateTime expire, {String sujet = 'a'}) {
  String part(Map<String, Object> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = expire.toUtc().millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'HS256'})}.${part({'sub': sujet, 'exp': exp})}.sig';
}

/// Repond au renouvellement par un jeton neuf, et note chaque requete avec
/// le jeton qu'elle portait.
class _Serveur implements HttpClientAdapter {
  _Serveur(this.neuf);

  final String neuf;
  final vues = <(String, String?)>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    vues.add((options.path, options.headers['Authorization'] as String?));
    final corps = options.path == '/auth/refresh'
        ? {'access_token': neuf, 'refresh_token': 'r2'}
        : <String, Object>{};
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(corps)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Retient les en-tetes de la derniere requete.
class _EnTetesVus implements HttpClientAdapter {
  Map<String, dynamic> enTetes = const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    enTetes = options.headers;
    return ResponseBody.fromBytes(
      utf8.encode('{}'),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
