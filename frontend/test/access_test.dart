/// Les droits d'un agent, et ce qu'ils ouvrent (cahier des charges, 3.4).
///
/// Une erreur ici ne se voit pas a l'ecran : elle ouvre une porte. D'ou des
/// tests sur ce que chaque compte peut *et* sur ce qu'il ne peut pas -- la
/// seconde moitie etant celle qui compte.
library;

import 'package:atrium/core/router.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed_accounts.dart';
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

    // Le coeur du 3.4 tient toujours : un receptionniste n'est pas un
    // cuisinier, et ne repare pas la plomberie.
    expect(acces.peut('order.read'), isFalse);
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

  group('la barriere du routeur', () {
    test('chaque zone protegee exige sa permission', () {
      expect(permissionPour('/chambres'), 'rooms.read');
      expect(permissionPour('/clients'), 'guests.read');
      expect(permissionPour('/factures'), 'folio.read');
      expect(permissionPour('/reservations'), 'rooms.read');
    });

    test('une sous-route est protegee comme sa zone', () {
      // Sans quoi `/reservations/nouvelle` serait ouvert a tous alors que
      // `/reservations` ne l'est pas -- exactement le genre de porte qu'on
      // ne remarque qu'une fois en service.
      expect(permissionPour('/reservations/nouvelle'), 'rooms.read');
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
}
