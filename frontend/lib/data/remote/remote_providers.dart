/// La couche reseau, exposee a l'application.
///
/// Volontairement peu exposee : seule la synchronisation et l'authentification
/// s'en servent. Les ecrans n'ont rien a faire ici — ils lisent Drift.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'auth_api.dart';
import 'token_store.dart';

/// Adresse du serveur central.
///
/// Se redefinit au lancement sans recompiler le code :
///
///   flutter run --dart-define=ATRIUM_API=http://192.168.1.20:8000/api/v1
///
/// Le defaut vise la machine de developpement. Sur une tablette Android,
/// `localhost` designe la tablette elle-meme : il faudra toujours passer
/// l'adresse du serveur de l'hotel.
const apiBaseUrl = String.fromEnvironment(
  'ATRIUM_API',
  defaultValue: 'http://localhost:8000/api/v1',
);

final tokenStoreProvider = Provider<TokenStore>((_) => const TokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(baseUrl: apiBaseUrl, tokens: ref.watch(tokenStoreProvider));
});

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(apiClientProvider), ref.watch(tokenStoreProvider)),
);
