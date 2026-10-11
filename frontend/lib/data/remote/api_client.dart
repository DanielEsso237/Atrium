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

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

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
      // Se connecter doit etre rapide : un serveur qui ne repond pas en 10 s
      // n'est pas la, et la tablette passe hors ligne. 5 s suffisaient sur le
      // reseau local ; a travers ngrok, la connexion fait un detour par
      // Internet, et en 3G elle depassait. Un serveur joignable peut aussi
      // etre lent -- un PC charge a mis plusieurs secondes a ecrire un point
      // de vente pendant les essais, et a 10 s la tablette abandonnait une
      // ecriture qui allait reussir. Les ecrans n'attendent pas ces
      // requetes : elles partent de la file, en arriere-plan.
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      contentType: Headers.jsonContentType,
      // Le serveur de test passe par ngrok, qui peut intercaler une page
      // d'avertissement HTML a la place de la reponse JSON. Cet en-tete l'en
      // dispense ; un serveur sans ngrok l'ignore.
      headers: {
        ..._dio.options.headers,
        'ngrok-skip-browser-warning': '1',
      },
      // On veut lire le corps des 4xx pour en extraire `detail` : sans cela
      // Dio leve avant qu'on ait vu le message du serveur.
      validateStatus: (code) => code != null && code < 500,
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          var token = await _tokens.readAccess();
          // Renouveler avant l'expiration plutot qu'apres le refus : sinon
          // chaque heure, une ecriture sur deux partait deux fois (401, puis
          // renouvellement, puis renvoi), et le journal du serveur se
          // remplissait de 401 qui ressemblaient a des pannes. Pas pour les
          // routes d'authentification elles-memes : le renouvellement y
          // passe, il ne doit pas se rappeler.
          //
          // L'heure est celle du serveur, pas celle de la tablette : une
          // tablette en avance d'une heure (fuseau mal regle) croyait chaque
          // jeton neuf deja expire, et renouvelait avant chaque requete.
          // Et jamais plus d'un renouvellement anticipe par minute, quoi
          // qu'il arrive : au pire, le serveur dira 401 et on renouvellera
          // alors.
          final maintenant = DateTime.now();
          final recent = _dernierAnticipe != null &&
              maintenant.difference(_dernierAnticipe!) < const Duration(minutes: 1);
          if (token != null &&
              !recent &&
              !options.path.startsWith('/auth/') &&
              expireBientot(token, maintenant.add(_decalage))) {
            _dernierAnticipe = maintenant;
            if (await _refresh()) token = await _tokens.readAccess();
          }
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          // L'heure du serveur, a chaque reponse : c'est elle qui juge
          // l'expiration du jeton.
          final heure = lireDateHttp(response.headers.value('date'));
          if (heure != null) _decalage = heure.difference(DateTime.now());
          handler.next(response);
        },
      ),
    );
  }

  /// Ecart entre l'horloge du serveur et celle de la tablette.
  Duration _decalage = Duration.zero;

  /// Le dernier renouvellement anticipe, pour ne jamais en enchainer.
  DateTime? _dernierAnticipe;

  /// Lit un en-tete HTTP `Date` (« Sat, 11 Oct 2026 10:00:00 GMT »).
  ///
  /// A la main : `HttpDate` vient de `dart:io`, absent de la version web.
  @visibleForTesting
  static DateTime? lireDateHttp(String? valeur) {
    if (valeur == null) return null;
    const mois = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug',
      'Sep', 'Oct', 'Nov', 'Dec'];
    final m = RegExp(
      r'(\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(valeur);
    if (m == null) return null;
    final rang = mois.indexOf(m.group(2)!);
    if (rang < 0) return null;
    return DateTime.utc(
      int.parse(m.group(3)!),
      rang + 1,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }

  /// Vrai si le jeton expire dans moins de deux minutes, ou s'il ne se lit
  /// pas. Lu sans verifier la signature : c'est le serveur qui juge, la
  /// tablette ne fait qu'anticiper.
  @visibleForTesting
  static bool expireBientot(String jeton, DateTime maintenant) {
    try {
      final parties = jeton.split('.');
      if (parties.length != 3) return false;
      final charge = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parties[1]))),
      );
      final exp = charge is Map ? charge['exp'] : null;
      if (exp is! num) return false;
      final limite = DateTime.fromMillisecondsSinceEpoch(
        (exp * 1000).toInt(),
        isUtc: true,
      );
      return limite.difference(maintenant.toUtc()) < const Duration(minutes: 2);
    } on Object {
      // Un jeton illisible n'est pas un jeton expire : on l'envoie, et le
      // serveur dira.
      return false;
    }
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

  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    return _asMap(await _send(() => _dio.put(path, data: body)));
  }

  Future<Map<String, dynamic>> delete(String path) async {
    return _asMap(await _send(() => _dio.delete(path)));
  }

  /// Lit un fichier binaire (le logo de l'hotel).
  Future<Uint8List> getBytes(String path) async {
    final data = await _send(
      () => _dio.get<List<int>>(
        path,
        options: Options(responseType: ResponseType.bytes),
      ),
    );
    return data is List<int> ? Uint8List.fromList(data) : Uint8List(0);
  }

  /// Envoie un fichier en `multipart/form-data`.
  ///
  /// Dix secondes suffisent a une ligne JSON, pas a une photo sur le Wi-Fi
  /// d'un couloir : l'envoi a ici une minute.
  Future<Map<String, dynamic>> putFile(String path, FormData form) async {
    return _asMap(
      await _send(
        () => _dio.put(
          path,
          data: form,
          options: Options(sendTimeout: const Duration(seconds: 60)),
        ),
      ),
    );
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
      // La cause exacte, dans la console : « hors ligne » recouvre un delai
      // depasse, un nom introuvable, un certificat refuse... et sans elle on
      // cherche des heures du mauvais cote.
      debugPrint(
        'Atrium : ${e.requestOptions.method} ${e.requestOptions.uri} '
        'a echoue (${e.type.name}) : ${e.error ?? e.message}',
      );
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
      // Fichier trop lourd : le renvoyer tel quel n'y changera rien.
      413 || 422 => ApiFailure.invalid,
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
    if (refresh == null) {
      // Pas de jeton de rafraichissement : soit la session date d'avant que
      // le serveur n'en emette, soit le magasin securise n'a rien conserve.
      // Le dire, sinon l'application se contente de deconnecter sans qu'on
      // sache pourquoi.
      debugPrint(
        'Atrium : aucun jeton de rafraichissement en magasin, '
        'la session ne peut pas etre prolongee. Se reconnecter.',
      );
      return false;
    }

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
