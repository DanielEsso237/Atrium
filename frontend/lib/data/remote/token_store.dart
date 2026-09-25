/// Conservation du jeton d'acces.
///
/// Dans le magasin securise de la plateforme (Keystore sur Android), et non
/// dans les preferences : une tablette de comptoir se perd, se vole, ou passe
/// de main en main. Un jeton en clair dans un fichier lisible donnerait acces
/// a tout l'hotel a qui sait ou regarder.
///
/// Le jeton survit au redemarrage de l'application : un agent qui relance la
/// tablette en plein service ne doit pas avoir a se reconnecter.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStore {
  const TokenStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  /// Copie en memoire du jeton, pour la duree de vie de l'application.
  ///
  /// Le magasin securise n'est pas disponible partout : sur le web il repose
  /// sur des API que le navigateur peut refuser, et l'echec etait avale en
  /// silence. Resultat vecu : la connexion reussissait, le serveur renvoyait
  /// un jeton, l'ecriture echouait, et **toutes** les requetes suivantes
  /// partaient sans en-tete d'autorisation. 401 partout, file d'envoi bloquee,
  /// et rien dans les logs pour l'expliquer.
  ///
  /// La memoire ne remplace pas le magasin -- elle ne survit pas au
  /// rechargement, et c'est voulu : un jeton ecrit ailleurs qu'en lieu sur
  /// serait un recul de securite pour un confort de developpement. Elle
  /// garantit seulement que la session tient pendant qu'on s'en sert.
  static final Map<String, String> _memoire = {};

  static const _accessKey = 'atrium.access_token';
  static const _refreshKey = 'atrium.refresh_token';
  static const _userKey = 'atrium.user_id';

  Future<String?> readAccess() => _read(_accessKey);
  Future<String?> readRefresh() => _read(_refreshKey);
  Future<String?> readUserId() => _read(_userKey);

  Future<void> save({
    required String accessToken,
    String? refreshToken,
    String? userId,
  }) async {
    await _write(_accessKey, accessToken);
    if (refreshToken != null) await _write(_refreshKey, refreshToken);
    if (userId != null) await _write(_userKey, userId);
  }

  Future<void> clear() async {
    for (final key in [_accessKey, _refreshKey, _userKey]) {
      await _delete(key);
    }
  }

  /// Le magasin securise peut echouer : navigateur en navigation privee,
  /// Keystore verrouille, plateforme sans implementation. L'echec ne doit
  /// jamais faire planter l'application — au pire l'agent se reconnecte.
  Future<String?> _read(String key) async {
    try {
      final stocke = await _storage.read(key: key);
      if (stocke != null) return stocke;
    } catch (e) {
      // Le dire plutot que de rendre `null` en silence : sans ce message, une
      // session qui ne survit pas au rechargement ressemble a un bug de
      // connexion, et on cherche des heures du mauvais cote.
      debugPrint('Atrium : lecture du magasin securise impossible ($key) : $e');
    }
    return _memoire[key];
  }

  Future<void> _write(String key, String value) async {
    // La memoire d'abord : elle ne peut pas echouer, et c'est elle qui fait
    // tenir la session si le magasin se derobe.
    _memoire[key] = value;
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      // Sans persistance, la session ne survit pas au redemarrage. C'est
      // degrade, pas casse -- mais il faut que ca se voie, sinon l'agent se
      // reconnecte sans cesse sans que personne ne comprenne pourquoi.
      debugPrint(
        'Atrium : ecriture dans le magasin securise impossible ($key) : $e. '
        'La session ne survivra pas au rechargement.',
      );
    }
  }

  Future<void> _delete(String key) async {
    _memoire.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }
}
