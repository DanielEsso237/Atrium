/// Le magasin de jetons, et son repli en memoire.
///
/// Vecu : la connexion reussissait, le serveur renvoyait un jeton, l'ecriture
/// dans le magasin securise echouait en silence, et toutes les requetes
/// suivantes partaient sans en-tete d'autorisation. 401 partout, file d'envoi
/// bloquee, et rien dans les logs pour l'expliquer.
library;

import 'package:atrium/data/remote/token_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un magasin qui refuse tout, comme le navigateur peut le faire.
class _MagasinEnPanne extends FlutterSecureStorage {
  const _MagasinEnPanne();

  @override
  Future<void> write({
    required String key,
    required String? value,
    // ignore: non_constant_identifier_names
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw UnsupportedError('magasin indisponible');
  }

  @override
  Future<String?> read({
    required String key,
    // ignore: non_constant_identifier_names
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw UnsupportedError('magasin indisponible');
  }

  @override
  Future<void> delete({
    required String key,
    // ignore: non_constant_identifier_names
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw UnsupportedError('magasin indisponible');
  }
}

void main() {
  const store = TokenStore(_MagasinEnPanne());

  setUp(() => store.clear());

  test('la session tient meme quand le magasin refuse tout', () async {
    await store.save(
      accessToken: 'acces-123',
      refreshToken: 'refresh-456',
      userId: 'agent-789',
    );

    // Sans le repli, ces trois lectures rendaient `null` et chaque requete
    // partait sans autorisation.
    expect(await store.readAccess(), 'acces-123');
    expect(await store.readRefresh(), 'refresh-456');
    expect(await store.readUserId(), 'agent-789');
  });

  test('la deconnexion efface aussi la memoire', () async {
    await store.save(accessToken: 'acces-123', refreshToken: 'r', userId: 'u');
    await store.clear();

    // Sinon l'agent suivant heriterait de la session du precedent, sur une
    // tablette que dix personnes se passent dans la journee.
    expect(await store.readAccess(), isNull);
    expect(await store.readRefresh(), isNull);
    expect(await store.readUserId(), isNull);
  });

  test('un jeton jamais ecrit reste absent', () async {
    expect(await store.readAccess(), isNull);
  });
}
