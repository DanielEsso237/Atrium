/// L'activite de demonstration : ce que les ecrans doivent afficher.
///
/// Ces tests ne remplacent pas un lancement sur tablette, mais ils verifient
/// la seule partie qui puisse etre fausse sans qu'on le voie : les chiffres.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/dashboard_queries.dart';
import 'package:atrium/data/local/queries/room_detail_queries.dart';
import 'package:atrium/data/local/queries/rooms_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_activity.dart';
import 'package:atrium/features/auth/auth_locale.dart';
// Import restreint : drift exporte aussi un `isNull`, qui masquerait celui
// de `matcher` et casserait les `expect(..., isNull)` de ce fichier.
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedDemoActivity(db);
  });
  tearDown(() async => db.close());

  test('l activite de demonstration est rejouable', () async {
    await seedDemoActivity(db);
    await seedDemoActivity(db);

    expect(await db.select(db.users).get(), hasLength(2));
    expect(await db.select(db.reservations).get(), hasLength(8));
    expect(await db.select(db.guests).get(), hasLength(8));
  });

  test('le plan montre les cinq etats du paragraphe 5.2', () async {
    final plan = await db.watchRoomBoard().first;
    final etats = plan.map((c) => c.displayStatus).toSet();

    expect(
      etats,
      containsAll(RoomDisplayStatus.values),
      reason: 'un ecran de demonstration qui ne montre que du vert '
          'ne prouve rien sur le calcul de la pastille',
    );
  });

  test('hors service l emporte sur tout le reste', () async {
    final plan = await db.watchRoomBoard().first;
    final horsService = plan.firstWhere((c) => c.number == '309');

    expect(horsService.isOutOfOrder, isTrue);
    expect(horsService.occupancy, OccupancyStatus.VACANT);
    expect(horsService.housekeeping, HousekeepingStatus.CLEAN);
    // Les trois axes disent « libre et propre », mais la chambre est
    // condamnee : c'est la priorite du calcul qui doit trancher.
    expect(horsService.displayStatus, RoomDisplayStatus.MAINTENANCE);
  });

  test('les tuiles du tableau de bord sont coherentes entre elles', () async {
    final r = await db.watchDashboard().first;
    final plan = await db.watchRoomBoard().first;

    expect(r.chambresTotal, plan.length);
    expect(
      r.chambresOccupees,
      plan.where((c) => c.occupancy == OccupancyStatus.OCCUPIED).length,
    );
    expect(
      r.chambresANettoyer,
      plan.where((c) => c.housekeeping == HousekeepingStatus.DIRTY).length,
    );
    expect(r.chambresOccupees, lessThanOrEqualTo(r.chambresTotal));
    expect(r.tauxOccupation, inInclusiveRange(0, 100));
  });

  test('le chiffre d affaires du jour n est pas vide', () async {
    final r = await db.watchDashboard().first;

    // Six sejours en cours facturent au moins leur nuitee : une tuile a zero
    // signalerait que les lignes d'ardoise ne portent pas la bonne journee.
    expect(r.caDuJour, greaterThan(0));
  });

  test('un taux d occupation sur zero chambre ne vaut pas zero', () async {
    final vide = AtriumDatabase.memory();
    addTearDown(vide.close);

    final r = await vide.watchDashboard().first;
    expect(r.chambresTotal, 0);
    expect(
      r.tauxOccupation,
      isNull,
      reason: 'afficher « 0 % d\'occupation » sur un hotel sans chambre '
          'serait faux, pas vide',
    );
  });

  test('la fiche d une chambre occupee porte son sejour et son ardoise', () async {
    final plan = await db.watchRoomBoard().first;
    final occupee = plan.firstWhere((c) => c.number == '101');

    final fiche = await db.watchFicheChambre(occupee.roomId).first;

    expect(fiche.estOccupee, isTrue);
    expect(fiche.sejour!.clientNom, 'Amadou Kone');
    expect(fiche.sejour!.tarifNuit, greaterThan(0));
    expect(fiche.consommations, isNotEmpty);
    expect(
      fiche.sejour!.soldeArdoise,
      fiche.consommations.fold<int>(0, (s, c) => s + c.montant),
      reason: 'le solde materialise doit egaler la somme des lignes',
    );
  });

  test('la fiche d une chambre libre ne porte aucun sejour', () async {
    final plan = await db.watchRoomBoard().first;
    final libre = plan.firstWhere((c) => c.number == '103');

    final fiche = await db.watchFicheChambre(libre.roomId).first;

    expect(fiche.estOccupee, isFalse);
    expect(fiche.sejour, isNull);
    expect(fiche.consommations, isEmpty);
  });

  group('connexion locale', () {
    test('le bon code et le bon PIN ouvrent la session', () async {
      final resultat = await AuthLocale(db).connecter(
        codeAgent: 'ADMIN01',
        secret: pinDemo,
      );

      expect(resultat.estReussie, isTrue);
      expect(resultat.utilisateur!.employeeCode, 'ADMIN01');
    });

    test('le code agent est insensible a la casse', () async {
      // Le clavier tactile met volontiers une minuscule : personne ne doit
      // echouer a se connecter pour cette raison.
      final resultat = await AuthLocale(db).connecter(
        codeAgent: '  admin01 ',
        secret: pinDemo,
      );

      expect(resultat.estReussie, isTrue);
    });

    test('un mauvais PIN est refuse', () async {
      final resultat =
          await AuthLocale(db).connecter(codeAgent: 'ADMIN01', secret: '0000');

      expect(resultat.estReussie, isFalse);
      expect(resultat.echec, EchecConnexion.secretInvalide);
    });

    test('un code inconnu est distingue d un mauvais PIN', () async {
      final resultat =
          await AuthLocale(db).connecter(codeAgent: 'FANTOME', secret: pinDemo);

      expect(resultat.echec, EchecConnexion.utilisateurInconnu);
    });

    test('le mot de passe ouvre aussi la session', () async {
      // Deux voies pour la meme identite : le PIN en service, le mot de passe
      // pour l'administration (cahier des charges 6.2).
      final resultat = await AuthLocale(db).connecter(
        codeAgent: 'ADMIN01',
        secret: motDePasseDemo,
      );

      expect(resultat.estReussie, isTrue);
    });

    test('le PIN ne passe pas pour un mot de passe, et inversement', () async {
      final auth = AuthLocale(db);

      // Les deux empreintes sont distinctes : une saisie qui vaut pour l'une
      // ne doit pas ouvrir l'autre par accident.
      expect(pinDemo, isNot(motDePasseDemo));
      expect(
        (await auth.connecter(codeAgent: 'ADMIN01', secret: 'ChangeMe')).echec,
        EchecConnexion.secretInvalide,
      );
    });

    test('une vraie empreinte serveur ne peut pas etre validee hors ligne', () {
      // Garde-fou : le jour ou de vraies empreintes bcrypt arriveront sans que
      // ce stub ait ete remplace, la connexion doit echouer bruyamment plutot
      // que d'accepter n'importe qui.
      const bcrypt = r'$2b$12$abcdefghijklmnopqrstuv';

      expect(AuthLocale.verifierSecret('1234', bcrypt), isFalse);
      expect(AuthLocale.verifierSecret('', bcrypt), isFalse);
      expect(AuthLocale.verifierSecret('1234', null), isFalse);
    });
  });

  group('roles', () {
    test('les sept roles du serveur sont semes', () async {
      final roles = await db.select(db.roles).get();
      expect(roles, hasLength(7));
      expect(
        roles.map((r) => r.code),
        containsAll(['ADMIN', 'RECEPTION', 'HOUSEKEEPING', 'MANAGER']),
      );
    });

    test('chaque compte de demonstration porte un role', () async {
      final liens = await db.select(db.userRoles).get();
      expect(liens, hasLength(2));
    });

    test('la reception et l administration n ouvrent pas au meme endroit',
        () async {
      // C'est le paragraphe 3.4 : une seule application, des interfaces
      // differentes selon le metier.
      Future<String?> accueil(String code) async {
        final r = await (db.select(db.roles)..where((t) => t.code.equals(code)))
            .getSingle();
        return r.homeRoute;
      }

      expect(await accueil('ADMIN'), '/');
      expect(await accueil('RECEPTION'), '/chambres');
    });

    test('la reception a moins de droits que l administration', () async {
      Future<Set<String>> droits(String roleCode) async {
        final role =
            await (db.select(db.roles)..where((t) => t.code.equals(roleCode)))
                .getSingle();
        final lignes = await db.customSelect(
          'SELECT p.code FROM role_permissions rp '
          'JOIN permissions p ON p.id = rp.permission_id '
          'WHERE rp.role_id = ?1',
          variables: [Variable.withString(role.id)],
        ).get();
        return lignes.map((l) => l.read<String>('code')).toSet();
      }

      final admin = await droits('ADMIN');
      final reception = await droits('RECEPTION');

      expect(reception, isNotEmpty);
      expect(reception.length, lessThan(admin.length));
      expect(reception, contains('rooms.read'));
      // La reception ne touche pas au restaurant ni a la maintenance.
      expect(reception, isNot(contains('order.read')));
      expect(reception, isNot(contains('maintenance.read')));
    });
  });
}
