/// Ce a quoi un agent a droit (cahier des charges, 3.4).
///
/// « Une seule application, des interfaces differentes selon le metier. » Le
/// serveur ne renvoie pas d'interface : il renvoie des permissions, et c'est
/// l'application qui en deduit ce qu'elle montre. Tout part donc d'ici.
///
/// Le calcul se fait une fois, a la connexion, et non a chaque widget : les
/// droits d'un agent ne changent pas pendant son service, et une jointure a
/// trois tables repetee sur chaque reconstruction d'ecran serait payee mille
/// fois pour rien.
library;

import 'package:drift/drift.dart';

import '../database.dart';

/// Les droits d'un agent, et l'ecran sur lequel il ouvre.
class AccessProfile {
  const AccessProfile({
    this.permissions = const {},
    this.homeRoute,
    this.roles = const [],
  });

  /// Les codes de permission, tels que `rooms.read`.
  final Set<String> permissions;

  /// L'ecran d'accueil du metier, ou `null` si le role n'en fixe pas.
  ///
  /// Un receptionniste ouvre sur le plan des chambres, pas sur le tableau de
  /// bord : c'est son outil de travail, et lui imposer un clic de plus a
  /// chaque prise de poste serait absurde.
  final String? homeRoute;

  /// Les intitules des roles, pour le dire a l'ecran.
  final List<String> roles;

  bool peut(String permission) => permissions.contains(permission);

  /// Un agent sans aucun role. Le cas existe : un compte cree et pas encore
  /// rattache. Il ne doit pas planter, seulement ne rien pouvoir.
  bool get vide => permissions.isEmpty;
}

/// Lit les droits d'un agent.
Future<AccessProfile> accessProfileFor(AtriumDatabase db, String userId) async {
  final lignes = await db
      .customSelect(
        '''
        SELECT p.code AS code
          FROM user_roles ur
          JOIN role_permissions rp ON rp.role_id = ur.role_id
          JOIN permissions p ON p.id = rp.permission_id
          JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = ? AND r.is_active = 1
        ''',
        variables: [Variable.withString(userId)],
        readsFrom: {db.userRoles, db.rolePermissions, db.permissions, db.roles},
      )
      .get();

  // Les roles sont lus a part : un agent peut en cumuler plusieurs, et tous
  // ne fixent pas d'accueil. Le premier qui en fixe un l'emporte, dans
  // l'ordre d'affichage -- une regle arbitraire, mais qui donne toujours le
  // meme resultat, ce qui vaut mieux qu'un ecran d'accueil qui change d'une
  // connexion a l'autre.
  final roles = await db
      .customSelect(
        '''
        SELECT r.label AS label, r.home_route AS home_route
          FROM user_roles ur
          JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = ? AND r.is_active = 1
         ORDER BY r.label
        ''',
        variables: [Variable.withString(userId)],
        readsFrom: {db.userRoles, db.roles},
      )
      .get();

  return AccessProfile(
    permissions: lignes.map((l) => l.read<String>('code')).toSet(),
    roles: roles.map((l) => l.read<String>('label')).toList(),
    homeRoute: roles
        .map((l) => l.read<String?>('home_route'))
        .where((r) => r != null && r.isNotEmpty)
        .firstOrNull,
  );
}
