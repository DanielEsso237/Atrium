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
}