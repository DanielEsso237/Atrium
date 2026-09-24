/// Connexion au serveur central.
///
/// `POST /api/v1/auth/login` prend du **JSON**, pas un formulaire : le
/// `tokenUrl` declare dans le schema OpenAPI ne sert qu'au bouton
/// « Authorize » de la documentation Swagger.
library;

import 'api_client.dart';
import 'token_store.dart';

/// Ce que le serveur renvoie a la connexion et au rafraichissement
/// (`TokenOut`).
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    this.userId = '',
  });

  final String accessToken;

  /// Echangeable contre une nouvelle paire tant qu'il n'a pas expire.
  /// C'est lui qui evite de redemander le mot de passe toutes les heures.
  final String refreshToken;

  /// Duree de vie du jeton d'acces, en secondes.
  final int expiresIn;

  final String userId;

  static AuthSession? fromJson(Map<String, dynamic> data) {
    final access = data['access_token'] as String?;
    final refresh = data['refresh_token'] as String?;
    if (access == null || refresh == null) return null;
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresIn: (data['expires_in'] as num?)?.toInt() ?? 0,
    );
  }
}

class AuthApi {
  const AuthApi(this._client, this._tokens);

  final ApiClient _client;
  final TokenStore _tokens;

  /// Se connecte et conserve la paire de jetons.
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

    final session = AuthSession.fromJson(data);
    if (session == null) {
      throw const ApiException(
        ApiFailure.server,
        'Reponse de connexion sans jeton.',
      );
    }

    await _tokens.save(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
    );

    // L'identifiant de l'agent vient de `GET /auth/me` : la reponse de login
    // ne porte que les jetons.
    final me = await _client.get('/auth/me');
    final userId = me['id'] as String? ?? '';
    await _tokens.save(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      userId: userId,
    );

    return AuthSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      expiresIn: session.expiresIn,
      userId: userId,
    );
  }

  /// Revoque le jeton de rafraichissement cote serveur, puis efface le
  /// magasin local.
  ///
  /// Une deconnexion hors ligne efface quand meme le magasin : l'agent
  /// suivant ne doit pas heriter de la session du precedent, serveur
  /// joignable ou non. Le jeton d'acces expire de lui-meme en 60 minutes.
  Future<void> logout() async {
    final refresh = await _tokens.readRefresh();
    if (refresh != null) {
      try {
        await _client.post('/auth/logout', body: {'refresh_token': refresh});
      } on ApiException {
        // Sans importance : le serveur nettoiera a l'expiration.
      }
    }
    await _tokens.clear();
  }

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
