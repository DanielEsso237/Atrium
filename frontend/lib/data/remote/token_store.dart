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

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStore {
  const TokenStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

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
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      // Sans persistance, la session ne survit pas au redemarrage. C'est
      // degrade, pas casse.
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }
}
