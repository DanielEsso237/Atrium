/// Remonter les ecritures d'un agent absent, sur le code d'un responsable
/// (correction 8).
///
/// Chacun ne remonte que ses ecritures (`OutboxEntries.authorId`) : celles
/// d'un agent qui ne repasse plus sur la tablette y restaient pour toujours.
/// Un responsable (`sync.monitor`) tape son code ; le serveur rend un jeton
/// court **au nom de l'absent** (`POST /auth/delegate`), et la file part avec
/// lui : chaque ecriture se juge avec les droits de son auteur, et le serveur
/// trace chacune au nom du responsable.
///
/// En ligne seulement : c'est le serveur qui verifie le code et delivre le
/// jeton, et un envoi hors ligne n'enverrait rien de toute facon.
library;

import '../local/database.dart';
import '../remote/api_client.dart';
import '../remote/auth_api.dart';
import '../remote/outbox_sender.dart';
import '../remote/signalement_blocages.dart';
import '../remote/token_store.dart';

/// Ce que l'envoi a donne, dit a l'ecran.
class EnvoiDelegue {
  const EnvoiDelegue({
    required this.responsable,
    required this.envoyees,
    required this.restantes,
    this.refus,
  });

  final String responsable;
  final int envoyees;

  /// Celles de l'absent qui restent : retenues derriere un refus.
  final int restantes;

  /// Le message du serveur, si l'une a ete refusee.
  final String? refus;
}

/// Le jeton delegue, et lui seul : ni rafraichissement, ni ecriture dans le
/// magasin -- la session de l'agent connecte n'y est pas touchee.
class JetonDelegue extends TokenStore {
  const JetonDelegue(this.jeton);

  final String jeton;

  @override
  Future<String?> readAccess() async => jeton;

  @override
  Future<String?> readRefresh() async => null;

  @override
  Future<String?> readUserId() async => null;

  @override
  Future<void> save({
    required String accessToken,
    String? refreshToken,
    String? userId,
  }) async {}

  @override
  Future<void> clear() async {}
}

class EnvoiPourAutrui {
  EnvoiPourAutrui({
    required this.db,
    required this.auth,
    required this.baseUrl,
    OutboxSender Function(TokenStore jetons)? moteur,
  }) : _moteur =
           moteur ??
           ((jetons) => OutboxSender(
             db: db,
             api: ApiClient(baseUrl: baseUrl, tokens: jetons),
           ));

  final AtriumDatabase db;
  final AuthApi auth;
  final String baseUrl;
  final OutboxSender Function(TokenStore jetons) _moteur;

  /// Remonte les ecritures de [auteurId]. Leve une [StateError] dont le
  /// message se lit tel quel a l'ecran.
  Future<EnvoiDelegue> envoyer({
    required String auteurId,
    required String code,
    required String secret,
    required String motif,
  }) async {
    final Map<String, dynamic> r;
    try {
      r = await auth.deleguer(
        auteurId: auteurId,
        employeeCode: code,
        secret: secret,
        motif: motif,
        tablette: await db.identifiantTablette(),
      );
    } on ApiException catch (e) {
      throw StateError(switch (e.failure) {
        ApiFailure.offline || ApiFailure.server =>
          'Serveur injoignable : un envoi pour un collègue se fait en ligne.',
        _ => e.message,
      });
    }
    final jeton = r['access_token'] as String?;
    if (jeton == null) throw StateError('Réponse du serveur illisible.');
    final qui = (r['approver'] as Map?) ?? const {};

    final rapport = await _moteur(JetonDelegue(jeton)).drain(pour: auteurId);
    return EnvoiDelegue(
      responsable: '${qui['first_name'] ?? ''} ${qui['last_name'] ?? ''}'
          .trim(),
      envoyees: rapport.envoyees,
      restantes: rapport.restantes,
      // Un refus, une coupure, un jeton expire en route : le dire.
      refus: switch (rapport.arret) {
        DrainStop.termine || DrainStop.attenteAutrui => null,
        _ => rapport.detail ?? 'Envoi interrompu.',
      },
    );
  }
}
