/// Activite de demonstration : de quoi faire vivre les ecrans avant l'API.
///
/// Volontairement **separe de `seed.dart`**. Celui-la est le miroir fidele du
/// parametrage du serveur (`backend/app/db/seed.py`) : hotel, etages,
/// categories, chambres. Celui-ci invente une journee d'hotel — des clients,
/// des sejours en cours, des consommations, des chambres sales — pour que le
/// tableau de bord affiche des chiffres et que le plan ait cinq couleurs.
///
/// Rien ici ne doit survivre a la connexion a l'API : quand la synchronisation
/// arrivera, ce fichier se supprime d'un bloc, sans toucher a `seed.dart`.
///
/// Les identifiants sont deterministes (segment `06`), donc l'appel est
/// rejouable : relancer l'application ne duplique rien.
library;

import 'package:drift/drift.dart';

import '../../core/formats.dart';
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
  ('01920000-0000-7000-8000-000000004005', 'HOUSEKEEPING', 'Housekeeping', null),
  ('01920000-0000-7000-8000-000000004006', 'MAINTENANCE', 'Maintenance', null),
  ('01920000-0000-7000-8000-000000004007', 'MANAGER', 'Manager / Direction', null),
];

/// Les permissions qui commandent les six boutons du tableau de bord.
///
/// Sous-ensemble assume de la liste du serveur, qui en compte une trentaine :
/// seules celles qui changent quelque chose a l'ecran aujourd'hui sont ici.
typedef _PermissionDemo = (String id, String code, String label, String module);

const _permissions = <_PermissionDemo>[
  ('01920000-0000-7000-8000-000000004104', 'rooms.read', 'Consulter le plan des chambres', 'rooms'),
  ('01920000-0000-7000-8000-000000004105', 'guests.read', 'Consulter les fiches clients', 'guests'),
  ('01920000-0000-7000-8000-000000004121', 'folio.read', 'Consulter les folios', 'folio'),
  ('01920000-0000-7000-8000-000000004123', 'order.read', 'Consulter les commandes restaurant', 'order'),
  ('01920000-0000-7000-8000-000000004126', 'housekeeping.read', 'Consulter les taches de nettoyage', 'housekeeping'),
  ('01920000-0000-7000-8000-000000004128', 'maintenance.read', 'Consulter les tickets de maintenance', 'maintenance'),
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

String _chambre(String numero) =>
    '01920000-0000-7000-8000-00000003${numero.padLeft(4, '0')}';

String _id(String suffixe) =>
    '01920000-0000-7000-8000-000000$suffixe'.padRight(36, '0').substring(0, 36);

/// Une chambre dont on force l'etat, pour que le plan montre les cinq couleurs.
typedef _EtatChambre = (String numero, OccupancyStatus, HousekeepingStatus, bool);

/// Les numeros doivent exister dans `seed.dart` : 101, 102, 103, 123, 201 a
/// 204, 301, 302, 309, 401 a 403, 501, 502, 510, 567. Une chambre inconnue est
/// ignoree sans bruit (voir plus bas) plutot que de faire echouer le semis.
const _etats = <_EtatChambre>[
  ('101', OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, false),
  ('102', OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, false),
  ('103', OccupancyStatus.VACANT, HousekeepingStatus.DIRTY, false),
  ('123', OccupancyStatus.RESERVED, HousekeepingStatus.CLEAN, false),
  ('201', OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, false),
  ('202', OccupancyStatus.VACANT, HousekeepingStatus.DIRTY, false),
  ('203', OccupancyStatus.RESERVED, HousekeepingStatus.CLEAN, false),
  ('204', OccupancyStatus.VACANT, HousekeepingStatus.IN_PROGRESS, false),
  ('301', OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, false),
  ('302', OccupancyStatus.VACANT, HousekeepingStatus.DIRTY, false),
  ('309', OccupancyStatus.VACANT, HousekeepingStatus.CLEAN, true),
  ('401', OccupancyStatus.OCCUPIED, HousekeepingStatus.CLEAN, false),
];

/// Un client et son sejour.
typedef _SejourDemo = (
  String cle,
  String prenom,
  String nom,
  String numeroChambre,
  int arriveeDansJours,
  int nuits,
  int tarif,
  ReservationStatus statut,
);

const _sejours = <_SejourDemo>[
  ('01', 'Amadou', 'Kone', '101', -2, 4, 25000, ReservationStatus.CHECKED_IN),
  ('02', 'Fatou', 'Diallo', '102', -1, 3, 45000, ReservationStatus.CHECKED_IN),
  ('03', 'Kwame', 'Mensah', '201', 0, 2, 60000, ReservationStatus.CHECKED_IN),
  ('04', 'Aline', 'Bamba', '301', 0, 5, 25000, ReservationStatus.CHECKED_IN),
  ('05', 'Ibrahim', 'Toure', '401', -3, 3, 45000, ReservationStatus.CHECKED_IN),
  ('06', 'Sarah', 'Nguessan', '123', 0, 2, 25000, ReservationStatus.CONFIRMED),
  ('07', 'Paul', 'Yao', '203', 0, 1, 60000, ReservationStatus.CONFIRMED),
  ('08', 'Marie', 'Kouassi', '202', 1, 3, 45000, ReservationStatus.CONFIRMED),
];

/// Consommations du jour, pour que la tuile « CA jour » ne soit pas a zero.
typedef _ChargeDemo = (String cleSejour, ChargeCategory, String libelle, int montant);

const _charges = <_ChargeDemo>[
  ('01', ChargeCategory.FNB, 'Diner restaurant', 18500),
  ('01', ChargeCategory.MINIBAR, 'Minibar - 2 boissons', 3000),
  ('02', ChargeCategory.FNB, 'Petit dejeuner x2', 9000),
  ('03', ChargeCategory.FNB, 'Room service', 22000),
  ('03', ChargeCategory.SPA, 'Massage 60 min', 35000),
  ('04', ChargeCategory.FNB, 'Bar - cocktails', 12500),
  ('05', ChargeCategory.LAUNDRY, 'Blanchisserie', 7500),
];

Future<void> seedDemoActivity(AtriumDatabase db) async {
  final maintenant = DateTime.now().toUtc();
  final aujourdhui = DateTime.now();

  await db.transaction(() async {
    // --- Personnel -----------------------------------------------------
    await db.into(db.users).insertOnConflictUpdate(
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

    await db.into(db.users).insertOnConflictUpdate(
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
      await db.into(db.roles).insertOnConflictUpdate(
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
      await db.into(db.permissions).insertOnConflictUpdate(
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
      await db.into(db.rolePermissions).insertOnConflictUpdate(
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
      await db.into(db.userRoles).insertOnConflictUpdate(
            UserRolesCompanion.insert(userId: userId, roleId: roleId),
          );
    }

    // --- Etats des chambres --------------------------------------------
    // Les trois axes sont ecrits separement : c'est tout l'interet du modele,
    // la pastille du plan se calcule ensuite a l'affichage.
    for (final (numero, occupation, menage, horsService) in _etats) {
      await (db.update(db.rooms)..where((r) => r.id.equals(_chambre(numero))))
          .write(
        RoomsCompanion(
          occupancyStatus: Value(occupation),
          housekeepingStatus: Value(menage),
          isOutOfOrder: Value(horsService),
          updatedAt: Value(maintenant),
        ),
      );
    }

    // --- Clients, sejours, ardoises -------------------------------------
    for (final s in _sejours) {
      final (cle, prenom, nom, numero, decalage, nuits, tarif, statut) = s;

      final guestId = _id('07$cle');
      final reservationId = _id('08$cle');
      final ligneId = _id('09$cle');
      final folioId = _id('10$cle');

      final arrivee = aujourdhui.add(Duration(days: decalage));
      final depart = arrivee.add(Duration(days: nuits));

      // Chambre absente du parametrage : on saute ce sejour plutot que de
      // faire echouer tout le semis.
      final typeChambre = await _typeDeLaChambre(db, numero);
      if (typeChambre == null) continue;

      await db.into(db.guests).insertOnConflictUpdate(
            GuestsCompanion.insert(
              id: guestId,
              createdAt: maintenant,
              updatedAt: maintenant,
              hotelId: _hotel,
              code: 'CLI-$cle',
              firstName: prenom,
              lastName: nom,
              syncState: const Value(SyncState.synced),
            ),
          );

      await db.into(db.reservations).insertOnConflictUpdate(
            ReservationsCompanion.insert(
              id: reservationId,
              createdAt: maintenant,
              updatedAt: maintenant,
              hotelId: _hotel,
              reference: 'RES-0000$cle',
              guestId: guestId,
              status: Value(statut),
              source: const Value(ReservationSource.DIRECT),
              arrivalDate: formatIsoDate(arrivee),
              departureDate: formatIsoDate(depart),
              estimatedTotal: Value(tarif * nuits),
              syncState: const Value(SyncState.synced),
            ),
          );

      await db.into(db.reservationRooms).insertOnConflictUpdate(
            ReservationRoomsCompanion.insert(
              id: ligneId,
              createdAt: maintenant,
              updatedAt: maintenant,
              reservationId: reservationId,
              roomTypeId: typeChambre,
              roomId: Value(_chambre(numero)),
              arrivalDate: formatIsoDate(arrivee),
              departureDate: formatIsoDate(depart),
              nightlyRate: Value(tarif),
              status: Value(statut),
              checkedInAt: statut == ReservationStatus.CHECKED_IN
                  ? Value(maintenant)
                  : const Value.absent(),
              syncState: const Value(SyncState.synced),
            ),
          );

      // Une ardoise n'existe que pour un sejour en cours : rien ne se
      // consomme avant d'etre arrive.
      if (statut == ReservationStatus.CHECKED_IN) {
        await db.into(db.folios).insertOnConflictUpdate(
              FoliosCompanion.insert(
                id: folioId,
                createdAt: maintenant,
                updatedAt: maintenant,
                hotelId: _hotel,
                number: 'FOL-0000$cle',
                type: const Value(FolioType.GUEST),
                status: const Value(FolioStatus.OPEN),
                reservationRoomId: Value(ligneId),
                guestId: Value(guestId),
                syncState: const Value(SyncState.synced),
              ),
            );
      }
    }

    // --- Consommations du jour ------------------------------------------
    final journee = formatIsoDate(aujourdhui);
    var rang = 0;

    for (final (cleSejour, categorie, libelle, montant) in _charges) {
      rang++;
      await db.into(db.folioItems).insertOnConflictUpdate(
            FolioItemsCompanion.insert(
              id: _id('11${rang.toString().padLeft(2, '0')}'),
              createdAt: maintenant,
              updatedAt: maintenant,
              folioId: _id('10$cleSejour'),
              category: categorie,
              label: libelle,
              unitPrice: Value(montant),
              amount: Value(montant),
              businessDate: journee,
              postedBy: const Value(utilisateurDemo),
              syncState: const Value(SyncState.synced),
            ),
          );
    }

    // Les nuitees de la journee, qui sont l'essentiel du chiffre d'affaires
    // d'un hotel : une ligne par sejour en cours.
    rang = 0;
    for (final s in _sejours) {
      final (cle, _, _, _, _, _, tarif, statut) = s;
      if (statut != ReservationStatus.CHECKED_IN) continue;
      rang++;

      await db.into(db.folioItems).insertOnConflictUpdate(
            FolioItemsCompanion.insert(
              id: _id('12${rang.toString().padLeft(2, '0')}'),
              createdAt: maintenant,
              updatedAt: maintenant,
              folioId: _id('10$cle'),
              category: ChargeCategory.ROOM,
              label: 'Nuitee du $journee',
              unitPrice: Value(tarif),
              amount: Value(tarif),
              businessDate: journee,
              postedBy: const Value(utilisateurDemo),
              syncState: const Value(SyncState.synced),
            ),
          );
    }

    // Les totaux de l'ardoise sont materialises : on les recalcule une fois,
    // comme le fera `_recompute_totals` cote serveur.
    await db.customStatement('''
      UPDATE folios
         SET charges_total = COALESCE((SELECT SUM(amount) FROM folio_items
                                        WHERE folio_id = folios.id
                                          AND deleted_at IS NULL), 0),
             balance       = COALESCE((SELECT SUM(amount) FROM folio_items
                                        WHERE folio_id = folios.id
                                          AND deleted_at IS NULL), 0)
                             - payments_total
    ''');
  });
}

/// Categorie de la chambre, lue depuis le parametrage deja seme.
///
/// `null` si le numero n'existe pas : le parametrage de `seed.dart` peut
/// changer, et un jeu de demonstration ne doit jamais empecher l'application
/// de demarrer pour une chambre renumerotee.
Future<String?> _typeDeLaChambre(AtriumDatabase db, String numero) async {
  final ligne = await (db.select(db.rooms)
        ..where((r) => r.id.equals(_chambre(numero))))
      .getSingleOrNull();
  return ligne?.roomTypeId;
}
