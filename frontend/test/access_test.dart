/// Les droits d'un agent, et ce qu'ils ouvrent (cahier des charges, 3.4).
///
/// Une erreur ici ne se voit pas a l'ecran : elle ouvre une porte. D'ou des
/// tests sur ce que chaque compte peut *et* sur ce qu'il ne peut pas -- la
/// seconde moitie etant celle qui compte.
library;

import 'package:atrium/core/router.dart';
import 'package:atrium/core/shell/app_shell.dart' show destinationsPour;
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedAccounts(db);
  });

  tearDown(() => db.close());

  Future<String> idDe(String codeAgent) async {
    final l = await db
        .customSelect(
          'SELECT id FROM users WHERE employee_code = ?',
          variables: [Variable.withString(codeAgent)],
        )
        .getSingle();
    return l.read<String>('id');
  }

  test('la reception voit son perimetre, et rien de plus', () async {
    final acces = await accessProfileFor(db, await idDe('RECEP01'));

    expect(acces.peut('rooms.read'), isTrue);
    expect(acces.peut('guests.read'), isTrue);
    expect(acces.peut('folio.read'), isTrue);

    // Le menage a rejoint son perimetre, et ce n'est pas un relachement : le
    // depart d'un client *ouvre* une tache de menage. La reception produit
    // donc ce travail, et doit pouvoir le declarer puis suivre ou il en est
    // pour savoir quelles chambres elle peut revendre. Sans ce droit elle
    // enregistrait un depart puis se faisait refuser la tache -- 403, file
    // d'envoi bloquee derriere.
    expect(acces.peut('housekeeping.read'), isTrue);

    // La reception est la caisse centrale, et aussi un point de vente
    // (decision du 8 octobre) : elle vend a son comptoir et recoit les
    // versements du soir. Les points de vente sont donc entres dans son
    // perimetre -- pour vendre, pas pour tenir la cuisine.
    expect(acces.peut('order.read'), isTrue);
    expect(acces.peut('cash.central'), isTrue);

    // Le coeur du 3.4 tient toujours : un receptionniste ne repare pas la
    // plomberie.
    expect(acces.peut('maintenance.read'), isFalse);
  });

  test('l\'administrateur a les six modules', () async {
    final acces = await accessProfileFor(db, await idDe('ADMIN01'));

    for (final p in [
      'rooms.read',
      'guests.read',
      'folio.read',
      'order.read',
      'housekeeping.read',
      'maintenance.read',
    ]) {
      expect(acces.peut(p), isTrue, reason: p);
    }
  });

  test('tout le monde ouvre sur le tableau de bord', () async {
    // Ouvrir directement sur un ecran fait gagner un clic a celui qui y
    // allait, et en coute un a tous les autres. Le mecanisme reste en place
    // pour un metier qui n'aura qu'un seul ecran.
    final reception = await accessProfileFor(db, await idDe('RECEP01'));
    final admin = await accessProfileFor(db, await idDe('ADMIN01'));

    expect(reception.homeRoute, '/');
    expect(admin.homeRoute, '/');
  });

  test('le role s\'affiche a cote du nom', () async {
    final acces = await accessProfileFor(db, await idDe('RECEP01'));
    expect(acces.roles, ['Reception']);
  });

  test('un agent sans role ne peut rien, et ne plante pas', () async {
    // Le cas existe des la mise en service : un compte cree le matin, rattache
    // l'apres-midi. Entre les deux, l'application doit rester debout.
    final acces = await accessProfileFor(db, 'inconnu-au-bataillon');

    expect(acces.vide, isTrue);
    expect(acces.roles, isEmpty);
    expect(acces.homeRoute, isNull);
    expect(acces.peut('rooms.read'), isFalse);
  });

  test("seul l'administrateur atteint l'administration", () async {
    // Le routeur la garde sous users.write : la reception et le menage ne
    // l'ont pas, meme en tapant l'adresse.
    expect(permissionPour('/administration'), 'users.write');
    final admin = await accessProfileFor(db, await idDe('ADMIN01'));
    final reception = await accessProfileFor(db, await idDe('RECEP01'));
    final menage = await accessProfileFor(db, await idDe('MENAGE01'));

    expect(admin.peut('users.write'), isTrue);
    expect(reception.peut('users.write'), isFalse);
    expect(menage.peut('users.write'), isFalse);
  });

  test("le menage ne voit que son ecran", () async {
    // Vecu : la femme de chambre voyait arrivees, departs, reservations et
    // plan -- gardes par rooms.read, qu'elle porte pour lire les numeros.
    final menage = await accessProfileFor(db, await idDe('MENAGE01'));
    final reception = await accessProfileFor(db, await idDe('RECEP01'));

    expect(menage.peut('housekeeping.read'), isTrue);
    expect(menage.peut(permissionPour('/chambres')!), isFalse);
    expect(menage.peut(permissionPour('/reservations')!), isFalse);
    expect(reception.peut(permissionPour('/chambres')!), isTrue);
    expect(reception.peut(permissionPour('/reservations')!), isTrue);
  });

  group('les metiers du stock', () {
    const roles = {
      'ECONOME': '01920000-0000-7000-8000-000000004008',
      'CONTROLEUR': '01920000-0000-7000-8000-000000004009',
      'COMPTABLE': '01920000-0000-7000-8000-000000004010',
    };

    // Un agent cree a l'administration et rattache a ce role : aucun compte
    // de demonstration ne porte ces metiers.
    Future<AccessProfile> agent(String role) async {
      final id = 'agent-$role';
      await db.customStatement(
        'INSERT INTO users (id, created_at, updated_at, hotel_id, '
        'employee_code, first_name, last_name) '
        "SELECT ?, created_at, updated_at, hotel_id, ?, 'Test', ? "
        "FROM users WHERE employee_code = 'ADMIN01'",
        [id, role, role],
      );
      await db.customStatement(
        'INSERT INTO user_roles (user_id, role_id) VALUES (?, ?)',
        [id, roles[role]],
      );
      return accessProfileFor(db, id);
    }

    test('l ecran « A valider » s ouvre au controleur et au comptable', () async {
      for (final role in ['CONTROLEUR', 'COMPTABLE']) {
        final acces = await agent(role);

        // Ils ouvrent sur les stocks, le routeur les y laisse entrer, et la
        // liste a valider leur est montree.
        expect(acces.homeRoute, '/stocks', reason: role);
        expect(acces.peut(permissionPour('/stocks')!), isTrue, reason: role);
        expect(acces.peut('stock.transfer.approve'), isTrue, reason: role);
        // Le second regard ne demande pas et ne saisit pas.
        expect(acces.peut('stock.transfer.request'), isFalse, reason: role);
        expect(acces.peut('stock.manage'), isFalse, reason: role);
        expect(acces.peut(permissionPour('/factures')!), isFalse, reason: role);
      }
    });

    test('l econome tient l economat et demande, sans valider', () async {
      final acces = await agent('ECONOME');

      expect(acces.homeRoute, '/stocks');
      expect(acces.peut('stock.read'), isTrue);
      expect(acces.peut('stock.manage'), isTrue);
      expect(acces.peut('stock.transfer.request'), isTrue);
      expect(acces.peut('stock.transfer.approve'), isFalse);
    });

    test('l administrateur garde tous les gestes du stock', () async {
      final acces = await accessProfileFor(db, await idDe('ADMIN01'));

      for (final p in [
        'stock.read',
        'stock.manage',
        'stock.transfer.request',
        'stock.transfer.approve',
      ]) {
        expect(acces.peut(p), isTrue, reason: p);
      }
    });
  });

  group('la barriere du routeur', () {
    test('chaque zone protegee exige sa permission', () {
      expect(permissionPour('/chambres'), 'reservation.read');
      expect(permissionPour('/clients'), 'guests.read');
      expect(permissionPour('/factures'), 'folio.read');
      expect(permissionPour('/reservations'), 'reservation.read');
    });

    test('une sous-route est protegee comme sa zone', () {
      // Sans quoi `/reservations/nouvelle` serait ouvert a tous alors que
      // `/reservations` ne l'est pas -- exactement le genre de porte qu'on
      // ne remarque qu'une fois en service.
      expect(permissionPour('/reservations/nouvelle'), 'reservation.read');
    });

    test('le tableau de bord et la connexion restent ouverts', () {
      // Le tableau de bord est le point de repli quand une route est refusee :
      // le proteger lui-meme ferait une boucle.
      expect(permissionPour('/'), isNull);
      expect(permissionPour('/connexion'), isNull);
    });

    test('un chemin voisin ne passe pas pour une zone protegee', () {
      // `/chambres-libres` n'est pas `/chambres` : la comparaison doit porter
      // sur le segment, pas sur le prefixe brut.
      expect(permissionPour('/chambres-libres'), isNull);
    });

    test('la reception franchit ses zones, pas les autres', () async {
      final acces = await accessProfileFor(db, await idDe('RECEP01'));

      bool passe(String chemin) {
        final requise = permissionPour(chemin);
        return requise == null || acces.peut(requise);
      }

      expect(passe('/chambres'), isTrue);
      expect(passe('/clients'), isTrue);
      expect(passe('/factures'), isTrue);
      expect(passe('/'), isTrue);
    });
  });

  test('desactiver un role retire les droits qu\'il donnait', () async {
    final id = await idDe('RECEP01');
    expect((await accessProfileFor(db, id)).peut('rooms.read'), isTrue);

    await db.customStatement(
      "UPDATE roles SET is_active = 0 WHERE code = 'RECEPTION'",
    );

    // Sans quoi desactiver un role serait cosmetique, et un agent ecarte
    // garderait ses acces jusqu'a ce que quelqu'un pense a le supprimer.
    final apres = await accessProfileFor(db, id);
    expect(apres.vide, isTrue);
    expect(apres.homeRoute, isNull);
  });

  test('les onglets suivent le genre des points de vente de l agent',
      () async {
    // Le rattachement seul compte ici : la base de demonstration n'a pas
    // d'hotel complet, on laisse donc les cles etrangeres de cote.
    await db.customStatement('PRAGMA foreign_keys = OFF');
    final points = OutletRepository(db);
    final bar = await points.create(code: 'BAR', label: 'Bar / Lounge');
    await points.create(code: 'SPA', label: 'Spa', kind: OutletKind.SERVICE);
    final barman = await idDe('RECEP01');
    await db.customStatement(
      'INSERT INTO user_outlets (user_id, outlet_id) VALUES '
      "('$barman', '${bar.id}')",
    );

    final acces = await accessProfileFor(db, barman);
    expect(acces.voitGenre('OUTLET'), isTrue);
    expect(acces.voitGenre('SERVICE'), isFalse);
    final routes = destinationsPour(SessionState(acces: acces))
        .map((d) => d.route);
    expect(routes, contains('/commandes'));
    expect(routes, isNot(contains('/services')));

    // Sans rattachement, l'administrateur voit les deux.
    final admin = await accessProfileFor(db, await idDe('ADMIN01'));
    expect(admin.voitGenre('OUTLET') && admin.voitGenre('SERVICE'), isTrue);
    expect(genreDeLaZone('/services'), 'SERVICE');
    expect(genreDeLaZone('/commandes/bar'), 'OUTLET');
    expect(genreDeLaZone('/stocks'), isNull);
  });
}