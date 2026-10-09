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

/// La femme de chambre. Meme identifiant que `DEMO_HOUSEKEEPING` cote serveur.
///
/// C'est le compte qui montre le paragraphe 3.4 le plus nettement : connectee,
/// elle ne voit ni le plan, ni les clients, ni les factures -- seulement ses
/// chambres a faire.
const _housekeeper = '01920000-0000-7000-8000-000000050003';

/// Le restaurant. Meme identifiant que `DEMO_RESTAURANT` cote serveur.
///
/// Quatrieme metier, quatrieme interface : il prend les commandes au bar, au
/// restaurant ou a la boite de nuit, et les porte sur l'ardoise de la chambre.

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
const _roleHousekeeping = '01920000-0000-7000-8000-000000004005';
const _roleRestaurant = '01920000-0000-7000-8000-000000004004';

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
  // La reception ouvre sur le tableau de bord, pas sur le plan des chambres.
  // Ouvrir directement sur un ecran fait gagner un clic a celui qui allait y
  // aller, et en coute un a tous les autres : il faut revenir en arriere pour
  // atteindre les clients, les reservations ou les factures. Le tableau de
  // bord est le carrefour, c'est de la qu'on part.
  //
  // La colonne garde son sens pour un metier qui n'a qu'un ecran -- le
  // housekeeping le jour ou il existera.
  (_roleReception, 'RECEPTION', 'Reception', '/'),
  ('01920000-0000-7000-8000-000000004003', 'CAISSE', 'Caisse', null),
  (_roleRestaurant, 'RESTAURANT', 'Points de vente', '/commandes'),
  (_roleHousekeeping, 'HOUSEKEEPING', 'Housekeeping', '/menage'),
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
  // Le nom, les coordonnees et le logo de l'hotel, en tete des factures.
  (
    '01920000-0000-7000-8000-000000004112',
    'hotel.write',
    "Modifier le parametrage de l'etablissement",
    'hotel',
  ),
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
    '01920000-0000-7000-8000-000000004106',
    'guests.write',
    'Creer ou modifier une fiche client',
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
  // Identifiant local : cote serveur, ...4131 est cash.session, mais ici il
  // designe deja reservation.read. Seul le code compte pour les droits.
  (
    '01920000-0000-7000-8000-000000004150',
    'cash.session',
    'Ouvrir et fermer sa session de caisse',
    'cash',
  ),
  // Les stocks (identifiants locaux, comme cash.session ci-dessus).
  (
    '01920000-0000-7000-8000-000000004151',
    'stock.read',
    'Consulter les stocks',
    'stock',
  ),
  (
    '01920000-0000-7000-8000-000000004152',
    'stock.movement',
    'Enregistrer un mouvement de stock',
    'stock',
  ),
  (
    '01920000-0000-7000-8000-000000004153',
    'stock.transfer.approve',
    'Valider ou refuser un transfert de stock',
    'stock',
  ),
  (
    '01920000-0000-7000-8000-000000004126',
    'housekeeping.read',
    'Consulter les taches de nettoyage',
    'housekeeping',
  ),
  (
    '01920000-0000-7000-8000-000000004127',
    'housekeeping.manage',
    'Creer, assigner, executer une tache de nettoyage',
    'housekeeping',
  ),
  (
    '01920000-0000-7000-8000-000000004128',
    'maintenance.read',
    'Consulter les tickets de maintenance',
    'maintenance',
  ),
  (
    '01920000-0000-7000-8000-000000004129',
    'maintenance.manage',
    'Creer, assigner, resoudre un ticket de maintenance',
    'maintenance',
  ),
  (
    '01920000-0000-7000-8000-000000004120',
    'reservation.manage',
    'Enregistrer arrivee/depart, annuler une reservation',
    'reservation',
  ),
  (
    '01920000-0000-7000-8000-000000004131',
    'reservation.read',
    'Consulter les reservations',
    'reservation',
  ),
  (
    '01920000-0000-7000-8000-000000004130',
    'users.write',
    'Administrer : agents, roles, points de vente, parametres',
    'users',
  ),
];

/// Qui a droit a quoi. L'administrateur a tout ; la reception voit le plan,
/// les clients et les folios, conformement au serveur.
const _droits = <(String role, String permission)>[
  (_roleAdmin, '01920000-0000-7000-8000-000000004112'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004104'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004105'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004121'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004123'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004126'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004127'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004128'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004129'),
  // L'administration, comme cote serveur : l'administrateur seul.
  (_roleAdmin, '01920000-0000-7000-8000-000000004130'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004131'),
  // Annuler un dossier, comme cote serveur : administration et reception.
  // Sans lui, le bouton d'annulation restait cache apres une connexion hors
  // ligne, faute des droits que le serveur aurait donnes.
  (_roleAdmin, '01920000-0000-7000-8000-000000004120'),
  (_roleReception, '01920000-0000-7000-8000-000000004120'),
  (_roleReception, '01920000-0000-7000-8000-000000004104'),
  (_roleReception, '01920000-0000-7000-8000-000000004105'),
  // Ecrire la fiche, comme cote serveur : c'est le droit qui ouvre les
  // photos de piece d'identite. Sans lui, apres une connexion hors ligne,
  // les cases Recto et Verso restaient grisees sans rien dire.
  (_roleAdmin, '01920000-0000-7000-8000-000000004106'),
  (_roleReception, '01920000-0000-7000-8000-000000004106'),
  (_roleReception, '01920000-0000-7000-8000-000000004121'),
  // Le plan et les reservations : l'ecran de la reception, pas du menage.
  (_roleReception, '01920000-0000-7000-8000-000000004131'),
  // La reception suit l'avancement du menage : c'est ce que compte deja sa
  // tuile « a nettoyer », et c'est elle qui decide quelles chambres revendre.
  (_roleReception, '01920000-0000-7000-8000-000000004126'),
  (_roleReception, '01920000-0000-7000-8000-000000004127'),
  // Un seul droit metier, un seul ecran. C'est tout le travail.
  (_roleHousekeeping, '01920000-0000-7000-8000-000000004126'),
  (_roleHousekeeping, '01920000-0000-7000-8000-000000004127'),
  // Plus la lecture des chambres : on ne nettoie pas un numero qu'on ignore.
  (_roleHousekeeping, '01920000-0000-7000-8000-000000004104'),
  // Le restaurant ne voit que ses commandes. Pas le plan, pas les clients,
  // pas les factures -- il porte a l'ardoise sans avoir a la consulter.
  (_roleRestaurant, '01920000-0000-7000-8000-000000004123'),
  // Le client de passage paie au comptoir (decision du 4 octobre) : le
  // comptoir ouvre une caisse, comme la reception et l'administration.
  (_roleRestaurant, '01920000-0000-7000-8000-000000004150'),
  (_roleReception, '01920000-0000-7000-8000-000000004150'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004150'),
  // Les stocks : l'administrateur, en attendant les roles econome,
  // controleur et comptable.
  (_roleAdmin, '01920000-0000-7000-8000-000000004151'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004152'),
  (_roleAdmin, '01920000-0000-7000-8000-000000004153'),
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

    await db
        .into(db.users)
        .insertOnConflictUpdate(
          UsersCompanion.insert(
            id: _housekeeper,
            createdAt: maintenant,
            updatedAt: maintenant,
            hotelId: _hotel,
            employeeCode: 'MENAGE01',
            firstName: 'Fatou',
            lastName: 'Sow',
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

    // Une permission deja connue sous un autre id -- creee par une connexion
    // en ligne, qui range les droits du serveur par leur code -- est reprise
    // telle quelle. La semer une seconde fois aurait fait deux lignes pour un
    // meme code, et la connexion suivante, qui cherche par code, aurait
    // echoue.
    final idReel = <String, String>{};
    for (final (id, code, label, module) in _permissions) {
      final connue = await (db.select(db.permissions)
            ..where((p) => p.code.equals(code) & p.id.equals(id).not())
            ..limit(1))
          .getSingleOrNull();
      if (connue != null) {
        idReel[id] = connue.id;
        continue;
      }
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
              permissionId: idReel[permissionId] ?? permissionId,
            ),
          );
    }

    // ADMIN01 administre, RECEP01 tient la reception : c'est ce rattachement
    // qui manquait pour que les deux comptes soient autre chose que deux noms.
    for (final (userId, roleId) in [
      (utilisateurDemo, _roleAdmin),
      (_receptionniste, _roleReception),
      (_housekeeper, _roleHousekeeping),
    ]) {
      await db
          .into(db.userRoles)
          .insertOnConflictUpdate(
            UserRolesCompanion.insert(userId: userId, roleId: roleId),
          );
    }
  });
}
