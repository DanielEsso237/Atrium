/// Comptes, roles et permissions de la tablette.
///
/// Complement de `seed.dart`, qui porte l'etablissement, les etages, les
/// categories et les chambres. Ici vivent les agents et leurs droits — le
/// pendant de ce que `backend/app/db/seed.py` seme cote serveur, avec les
/// memes identifiants.
///
/// **L'activite de demonstration a ete retiree** : clients, sejours et
/// consommations se creent maintenant pour de vrai, depuis l'application et
/// dans PostgreSQL. Il ne reste ici que ce sans quoi personne ne pourrait se
/// connecter.
///
/// Les deux comptes gardent une empreinte `DEMO:` parce que le serveur ne
/// renvoie pas les empreintes de mot de passe : sans eux, aucune connexion
/// hors ligne ne serait possible. Ils disparaitront quand la table `users`
/// descendra avec ses empreintes.
library;

import 'package:drift/drift.dart';

import 'database.dart';
import 'enums.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

/// Meme identifiant et meme code que l'administrateur du serveur, pour que la
/// bascule vers la vraie authentification ne change pas d'utilisateur.
const utilisateurDemo = '01920000-0000-7000-8000-000000050001';
const _receptionniste = '01920000-0000-7000-8000-000000050002';

/// Code PIN du jeu de demonstration.
///
/// Le prefixe `DEMO:` n'est pas une empreinte : c'est un marqueur explicite.
/// Voir `AuthLocale.verifierSecret` — une vraie empreinte bcrypt venue du
/// serveur ne peut pas etre validee hors ligne par ce stub, et echouera
/// bruyamment au lieu d'accepter n'importe quoi en silence.
const pinDemo = '1234';
const _pinStocke = 'DEMO:$pinDemo';

/// Mot de passe du jeu de demonstration, identique a celui du serveur
/// (`DEMO_ADMIN_PASSWORD` dans backend/app/db/seed.py).
const motDePasseDemo = 'ChangeMe123!';
const _motDePasseStocke = 'DEMO:$motDePasseDemo';

// --- Roles ------------------------------------------------------------------
// Memes identifiants et memes codes que le serveur, pour que la bascule vers
// la vraie synchronisation ne renumerote rien.
const _roleAdmin = '01920000-0000-7000-8000-000000004001';
const _roleReception = '01920000-0000-7000-8000-000000004002';

/// Un role, avec l'ecran sur lequel il ouvre apres connexion.
///
/// `homeRoute` porte le paragraphe 3.4 du cahier des charges : une seule
/// application, des interfaces differentes selon le metier. Un receptionniste
/// travaille sur le plan des chambres, l'administrateur sur le tableau de
/// bord. Le serveur laisse cette colonne nulle pour l'instant ; c'est une
/// valeur de parametrage, a reporter cote serveur quand l'ecran
/// d'administration des roles existera.
typedef _RoleDemo = (String id, String code, String label, String? accueil);

const _roles = <_RoleDemo>[
  (_roleAdmin, 'ADMIN', 'Administrateur', '/'),
  (_roleReception, 'RECEPTION', 'Reception', '/chambres'),
  ('01920000-0000-7000-8000-000000004003', 'CAISSE', 'Caisse', null),
  ('01920000-0000-7000-8000-000000004004', 'RESTAURANT', 'Restauration', null),
  (
    '01920000-0000-7000-8000-000000004005',
    'HOUSEKEEPING',
    'Housekeeping',
    null,
  ),
  ('01920000-0000-7000-8000-000000004006', 'MAINTENANCE', 'Maintenance', null),
  (
    '01920000-0000-7000-8000-000000004007',
    'MANAGER',
    'Manager / Direction',
    null,
  ),
];

/// Les permissions qui commandent les six boutons du tableau de bord.
///
/// Sous-ensemble assume de la liste du serveur, qui en compte une trentaine :
/// seules celles qui changent quelque chose a l'ecran aujourd'hui sont ici.
typedef _PermissionDemo = (String id, String code, String label, String module);

const _permissions = <_PermissionDemo>[
  (
    '01920000-0000-7000-8000-000000004104',
    'rooms.read',
    'Consulter le plan des chambres',
    'rooms',
  ),
  (
    '01920000-0000-7000-8000-000000004105',
    'guests.read',
    'Consulter les fiches clients',
    'guests',
  ),
  (
    '01920000-0000-7000-8000-000000004121',
    'folio.read',
    'Consulter les folios',
    'folio',
  ),
  (
    '01920000-0000-7000-8000-000000004123',
    'order.read',
    'Consulter les commandes restaurant',
    'order',
  ),
  (
    '01920000-0000-7000-8000-000000004126',
    'housekeeping.read',
    'Consulter les taches de nettoyage',
    'housekeeping',
  ),
  (
    '01920000-0000-7000-8000-000000004128',
    'maintenance.read',
    'Consulter les tickets de maintenance',
    'maintenance',
  ),
];

/// Qui a droit a quoi. L'administrateur a tout ; la reception voit le plan,
/// les clients et les folios, conformement au serveur.
const _droits = <(String role, String permission)>[
  (_roleAdmin, '01920000-0000-7000-8000-000000004104'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004105'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004121'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004123'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004126'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004128'),
  (_roleReception, '01920000-0000-7000-8000-000000004104'),
  (_roleReception, '01920000-0000-7000-8000-000000004105'),
  (_roleReception, '01920000-0000-7000-8000-000000004121'),
];

Future<void> seedAccounts(AtriumDatabase db) async {
  final maintenant = DateTime.now().toUtc();

  await db.transaction(() async {
    // --- Personnel -----------------------------------------------------
    await db
        .into(db.users)
        .insertOnConflictUpdate(
          UsersCompanion.insert(
            id: utilisateurDemo,
            createdAt: maintenant,
            updatedAt: maintenant,
            hotelId: _hotel,
            employeeCode: 'ADMIN01',
            firstName: 'Admin',
            lastName: 'Atrium',
            email: const Value('admin@atrium.local'),
            pinHash: const Value(_pinStocke),
            passwordHash: const Value(_motDePasseStocke),
            mustChangePassword: const Value(false),
            syncState: const Value(SyncState.synced),
          ),
        );

    await db
        .into(db.users)
        .insertOnConflictUpdate(
          UsersCompanion.insert(
            id: _receptionniste,
            createdAt: maintenant,
            updatedAt: maintenant,
            hotelId: _hotel,
            employeeCode: 'RECEP01',
            firstName: 'Awa',
            lastName: 'Traore',
            pinHash: const Value(_pinStocke),
            passwordHash: const Value(_motDePasseStocke),
            mustChangePassword: const Value(false),
            syncState: const Value(SyncState.synced),
          ),
        );

    // --- Roles, permissions, rattachements -------------------------------
    for (final (id, code, label, accueil) in _roles) {
      await db
          .into(db.roles)
          .insertOnConflictUpdate(
            RolesCompanion.insert(
              id: id,
              createdAt: maintenant,
              updatedAt: maintenant,
              code: code,
              label: label,
              isSystem: const Value(true),
              homeRoute: Value(accueil),
              syncState: const Value(SyncState.synced),
            ),
          );
    }

    for (final (id, code, label, module) in _permissions) {
      await db
          .into(db.permissions)
          .insertOnConflictUpdate(
            PermissionsCompanion.insert(
              id: id,
              createdAt: maintenant,
              updatedAt: maintenant,
              code: code,
              label: label,
              module: module,
            ),
          );
    }

    for (final (roleId, permissionId) in _droits) {
      await db
          .into(db.rolePermissions)
          .insertOnConflictUpdate(
            RolePermissionsCompanion.insert(
              roleId: roleId,
              permissionId: permissionId,
            ),
          );
    }

    // ADMIN01 administre, RECEP01 tient la reception : c'est ce rattachement
    // qui manquait pour que les deux comptes soient autre chose que deux noms.
    for (final (userId, roleId) in [
      (utilisateurDemo, _roleAdmin),
      (_receptionniste, _roleReception),
    ]) {
      await db
          .into(db.userRoles)
          .insertOnConflictUpdate(
            UserRolesCompanion.insert(userId: userId, roleId: roleId),
          );
    }
  });
}
