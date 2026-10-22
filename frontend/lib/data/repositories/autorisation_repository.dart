/// Le code d'un responsable, pour un geste qu'un agent ne s'autorise pas seul.
///
/// Demande du 16 octobre : annuler une arrivee, un depart ou un encaissement
/// exige le code d'un superieur, **meme quand c'est lui qui est connecte**.
/// L'agent doit aller le chercher ; le responsable tape son code sur la
/// tablette. Ce qui part ensuite par la file porte son identifiant, et le
/// serveur reverifie son droit a la reception.
///
/// Meme partage que la connexion (`AuthRepository`) :
///
/// 1. le serveur repond -- il juge, et la tablette ne repasse pas derriere
///    un refus ;
/// 2. le serveur ne repond pas -- la tablette verifie l'empreinte locale et
///    les droits qu'elle connait. Seuls les comptes dont l'empreinte est
///    descendue sur la tablette peuvent alors autoriser.
library;

import '../../features/auth/auth_locale.dart';
import '../local/database.dart';
import '../local/queries/access_queries.dart';
import '../remote/api_client.dart';
import '../remote/auth_api.dart';

/// Le droit d'autoriser une annulation, le meme que le serveur.
const droitAnnuler = 'operations.undo';

/// Qui a autorise.
class Responsable {
  const Responsable({required this.id, required this.nom});

  final String id;
  final String nom;
}

class AutorisationRepository {
  const AutorisationRepository(this.db, this._api);

  final AtriumDatabase db;
  final AuthApi _api;

  /// Verifie le code et le droit. Leve une [StateError] dont le message se
  /// lit tel quel a l'ecran.
  Future<Responsable> verifier({
    required String code,
    required String secret,
    String permission = droitAnnuler,
  }) async {
    try {
      final r = await _api.authorize(
        employeeCode: code,
        secret: secret,
        permission: permission,
      );
      final id = r['user_id'] as String?;
      if (id == null) throw StateError('Réponse du serveur illisible.');
      return Responsable(
        id: id,
        nom: '${r['first_name'] ?? ''} ${r['last_name'] ?? ''}'.trim(),
      );
    } on ApiException catch (e) {
      switch (e.failure) {
        case ApiFailure.forbidden:
        case ApiFailure.locked:
        case ApiFailure.notFound:
        case ApiFailure.invalid:
          throw StateError(e.message);
        default:
          return _verifierIci(code, secret, permission);
      }
    }
  }

  Future<Responsable> _verifierIci(
    String code,
    String secret,
    String permission,
  ) async {
    final agent = await agentParCode(db, code);
    final maintenant = DateTime.now().toUtc();
    if (agent != null && await estBloque(db, agent, maintenant)) {
      throw StateError('Compte du responsable bloqué après cinq codes faux.');
    }
    if (agent == null ||
        !agent.isActive ||
        !await AuthLocale.secretAccepte(secret, agent)) {
      // Le meme compte que le serveur : sans lui, la fenetre servirait a
      // deviner un PIN de responsable hors ligne.
      if (agent != null) await compterEchec(db, agent, maintenant);
      throw StateError(
        'Code du responsable incorrect, ou inconnu de cette tablette hors '
        'ligne.',
      );
    }
    final acces = await accessProfileFor(db, agent.id);
    final nom = '${agent.firstName} ${agent.lastName}'.trim();
    if (!acces.peut(permission)) {
      throw StateError("$nom n'a pas le droit d'autoriser ce geste.");
    }
    return Responsable(id: agent.id, nom: nom);
  }
}
