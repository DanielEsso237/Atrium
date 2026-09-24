/// Le client HTTP vers le serveur central.
///
/// **Aucun ecran n'appelle cet objet.** Les widgets lisent Drift ; c'est la
/// couche de synchronisation qui utilise ce client, en arriere-plan, pour
/// alimenter la base locale et vider la file d'attente. Si un widget importe
/// ce fichier, la conception a derape — et le mode hors connexion avec elle.
///
/// Conventions du contrat (`docs/04-contrat-api.md`) : montants en entiers,
/// taux en points de base, dates seules en `AAAA-MM-JJ`, instants en ISO-8601
/// UTC, identifiants generes par la tablette.
library;

import 'package:dio/dio.dart';

import 'token_store.dart';

/// Ce qui a echoue, sous une forme exploitable par l'appelant.
///
/// Dio leve des `DioException` de six natures differentes ; les distinguer au
/// cas par cas dans chaque appel serait a refaire partout. On les traduit une
/// fois, ici.
enum ApiFailure {
  /// Pas de reseau, serveur injoignable, delai depasse. **Ce n'est pas une
  /// erreur** pour une application hors ligne d'abord : c'est l'etat normal
  /// d'une tablette dans un couloir.
  offline,

  /// Jeton absent, invalide ou expire.
  unauthorized,

  /// Droit manquant. A distinguer de `unauthorized` : se reconnecter n'y
  /// changera rien.
  forbidden,

  /// Compte verrouille apres cinq echecs. Le serveur le relache au bout de
  /// quinze minutes ; inutile de reessayer avant, et surtout inutile de
  /// laisser l'agent croire qu'il se trompe de mot de passe.
  locked,

  /// Introuvable, ou appartenant a un autre hotel.
  notFound,

  /// Conflit d'etat : arrivee deja enregistree, folio deja clos.
  conflict,

  /// Corps invalide. C'est un defaut de l'application, pas de l'utilisateur.
  invalid,

  /// Le serveur a echoue.
  server,
}

class ApiException implements Exception {
  const ApiException(this.failure, this.message);

  final ApiFailure failure;
  final String message;

  bool get isOffline => failure == ApiFailure.offline;

  @override
  String toString() => 'ApiException($failure) : $message';
}

class ApiClient {
  ApiClient({
    required String baseUrl,
    required TokenStore tokens,
    Dio? dio,
    Future<void> Function()? onUnauthorized,
  }) : _tokens = tokens,
       _onUnauthorized = onUnauthorized,
       _dio = dio ?? Dio() {
    _dio.options = _dio.options.copyWith(
      baseUrl: baseUrl,
      // Delais courts : l'exigence 6.1 demande moins de deux secondes pour
      // toute action courante. Au-dela, mieux vaut basculer hors ligne et
      // laisser la file d'attente faire son travail que de figer l'ecran.
      connectTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      contentType: Headers.jsonContentType,
      // On veut lire le corps des 4xx pour en extraire `detail` : sans cela
      // Dio leve avant qu'on ait vu le message du serveur.
      validateStatus: (code) => code != null && code < 500,
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _tokens.readAccess();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
      ),
    );
  }

  final Dio _dio;
  final TokenStore _tokens;
  final Future<void> Function()? _onUnauthorized;

  /// Le rafraichissement en cours, s'il y en a un.
  Future<bool>? _refreshing;

  Dio get raw => _dio;

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    return _asMap(await _send(() => _dio.get(path, queryParameters: query)));
  }

  Future<List<dynamic>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final data = await _send(() => _dio.get(path, queryParameters: query));
    return data is List ? data : const [];
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    return _asMap(
      await _send(() => _dio.post(path, data: body, queryParameters: query)),
    );
  }

  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    return _asMap(await _send(() => _dio.patch(path, data: body)));
  }

  Map<String, dynamic> _asMap(Object? data) =>
      data is Map<String, dynamic> ? data : <String, dynamic>{};

  /// Envoie, traduit les echecs, et previent en cas de 401.
  Future<Object?> _send(
    Future<Response<dynamic>> Function() call, {
    bool isRetry = false,
  }) async {
    final Response<dynamic> response;
    try {
      response = await call();
    } on DioException catch (e) {
      throw ApiException(_failureOf(e), _messageOf(e));
    }

    final code = response.statusCode ?? 0;
    if (code >= 200 && code < 300) return response.data;

    final failure = switch (code) {
      401 => ApiFailure.unauthorized,
      403 => ApiFailure.forbidden,
      423 => ApiFailure.locked,
      404 => ApiFailure.notFound,
      409 => ApiFailure.conflict,
      422 => ApiFailure.invalid,
      _ => ApiFailure.server,
    };

    if (failure == ApiFailure.unauthorized && !isRetry) {
      // Le jeton d'acces vit 60 minutes. Sans ce rafraichissement, une
      // tablette en mode kiosque deconnecterait son agent une fois par
      // heure, en plein service.
      if (await _refresh()) return _send(call, isRetry: true);

      // Le rafraichissement a echoue : la session est reellement finie.
      await _tokens.clear();
      await _onUnauthorized?.call();
    }

    throw ApiException(failure, _detailOf(response.data));
  }

  /// Echange le jeton de rafraichissement contre une nouvelle paire.
  ///
  /// Renvoie `true` si la requete d'origine peut etre rejouee.
  ///
  /// Un seul echange a la fois : cinq requetes qui prennent un 401 ensemble
  /// ne doivent pas lancer cinq rafraichissements concurrents. Les quatre
  /// dernieres attendent le resultat du premier -- le serveur verrouille la
  /// ligne de son cote, mais autant ne pas l'y obliger.
  Future<bool> _refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final refresh = await _tokens.readRefresh();
    if (refresh == null) return false;

    try {
      // Requete nue, sans repasser par `_send` : un 401 sur le
      // rafraichissement lui-meme doit s'arreter la, pas relancer la
      // mecanique.
      final response = await _dio.post(
        '/auth/refresh',
        data: {'refresh_token': refresh},
      );
      final code = response.statusCode ?? 0;
      if (code < 200 || code >= 300) return false;

      final data = response.data;
      if (data is! Map) return false;
      final access = data['access_token'] as String?;
      final nouveau = data['refresh_token'] as String?;
      if (access == null || nouveau == null) return false;

      // Le serveur emet un NOUVEAU jeton de rafraichissement a chaque
      // echange : garder l'ancien conduirait a se faire refuser au suivant.
      await _tokens.save(accessToken: access, refreshToken: nouveau);
      return true;
    } on DioException {
      // Serveur injoignable pendant l'echange : la session n'est pas
      // forcement finie, mais cette requete-ci ne passera pas.
      return false;
    }
  }

  ApiFailure _failureOf(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.connectionError => ApiFailure.offline,
    _ => ApiFailure.server,
  };

  String _messageOf(DioException e) => _failureOf(e) == ApiFailure.offline
      ? 'Serveur injoignable.'
      : (e.message ?? 'Echec de la requete.');

  /// Extrait le message du serveur.
  ///
  /// `detail` est une chaine sur les erreurs metier, mais un **tableau**
  /// d'objets `{loc, msg, type}` sur une 422. Les deux formes existent, il
  /// faut les gerer ici plutot que dans chaque appelant.
  String _detailOf(Object? data) {
    if (data is! Map) return 'Erreur du serveur.';
    final detail = data['detail'];

    if (detail is String) return detail;
    if (detail is List && detail.isNotEmpty) {
      final first = detail.first;
      if (first is Map && first['msg'] != null) {
        final champ = (first['loc'] as List?)?.join('.') ?? '';
        return champ.isEmpty ? '${first['msg']}' : '$champ : ${first['msg']}';
      }
    }
    return 'Erreur du serveur.';
  }
}
