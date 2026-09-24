/// Connexion au serveur central.
///
/// `POST /api/v1/auth/login` prend du **JSON**, pas un formulaire : le
/// `tokenUrl` declare dans le schema OpenAPI ne sert qu'au bouton
/// « Authorize » de la documentation Swagger.
library;

import 'api_client.dart';
import 'token_store.dart';

/// Ce que le serveur renvoie a la connexion.
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.userId,
    this.refreshToken,
  });

  final String accessToken;
  final String userId;

  /// Pas encore emis par le serveur : `POST /auth/refresh` n'existe pas.
  /// Le champ est la pour que la bascule ne change rien aux appelants.
  final String? refreshToken;
}

class AuthApi {
  const AuthApi(this._client, this._tokens);

  final ApiClient _client;
  final TokenStore _tokens;

  /// Se connecte et conserve le jeton.
  ///
  /// Leve une `ApiException` : `offline` si le serveur est injoignable — ce
  /// qui n'est pas une erreur pour une tablette dans un couloir, mais un cas
  /// que l'appelant doit distinguer d'un mauvais mot de passe.
  Future<AuthSession> login({
    required String employeeCode,
    required String secret,
  }) async {
    final data = await _client.post(
      '/auth/login',
      body: {
        'employee_code': employeeCode.trim().toUpperCase(),
        'password': secret,
      },
    );

    final token = data['access_token'] as String?;
    if (token == null) {
      throw const ApiException(
        ApiFailure.server,
        'Reponse de connexion sans jeton.',
      );
    }

    // L'identifiant de l'agent vient de `GET /auth/me` : la reponse de login
    // ne porte que le jeton.
    await _tokens.save(accessToken: token);
    final me = await _client.get('/auth/me');
    final userId = me['id'] as String? ?? '';

    await _tokens.save(accessToken: token, userId: userId);

    return AuthSession(accessToken: token, userId: userId);
  }

  Future<void> logout() => _tokens.clear();

  /// L'agent deja connecte, si un jeton valide a survecu au redemarrage.
  ///
  /// Renvoie `null` hors ligne comme sur jeton expire : dans les deux cas
  /// l'application retombe sur la base locale, qui est de toute facon sa
  /// source d'affichage.
  Future<String?> currentUserId() async {
    if (await _tokens.readAccess() == null) return null;
    try {
      final me = await _client.get('/auth/me');
      return me['id'] as String?;
    } on ApiException {
      return await _tokens.readUserId();
    }
  }
}
