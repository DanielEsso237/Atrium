/// Un role ne doit exister qu'une fois par code.
///
/// Vecu le 11 octobre : ECONOME, CONTROLEUR et COMPTABLE en deux exemplaires
/// sur la tablette -- l'un descendu du serveur sous un identifiant tire au
/// hasard, l'autre seme au demarrage sous l'identifiant fixe. La fiche agent
/// plantait, et la descente, qui cherche un role par son code, aussi.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/agent_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

const _econome = '01920000-0000-7000-8000-000000004008';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedAccounts(db);
  });

  tearDown(() => db.close());

  Future<List<RoleRow>> economes() =>
      (db.select(db.roles)..where((r) => r.code.equals('ECONOME'))).get();

  test('un doublon existant est fondu dans le role seme au demarrage',
      () async {
    // L'etat de la tablette : un second ECONOME, et un agent qui le porte.
    final doublon = newId();
    final now = DateTime.now().toUtc();
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: doublon, createdAt: now, updatedAt: now,
            code: 'ECONOME', label: 'Econome',
          ),
        );
    final agent = (await db.select(db.users).get()).first.id;
    await db
        .into(db.userRoles)
        .insert(UserRolesCompanion.insert(userId: agent, roleId: doublon));
    expect(await economes(), hasLength(2));

    await seedAccounts(db);

    final restants = await economes();
    expect(restants.single.id, _econome);
    final portes = await (db.select(db.userRoles)
          ..where((ur) => ur.userId.equals(agent)))
        .get();
    expect(portes.map((ur) => ur.roleId), contains(_econome));
    expect(portes.map((ur) => ur.roleId), isNot(contains(doublon)));
  });

  test('un role descendu du serveur garde son identifiant', () async {
    await AgentRepository(db).applyServerRole({
      'id': '01920000-0000-7000-8000-0000000040aa',
      'code': 'BAGAGISTE',
      'label': 'Bagagiste',
      'permissions': <String>[],
    });
    final role = await (db.select(db.roles)
          ..where((r) => r.code.equals('BAGAGISTE')))
        .getSingle();
    expect(role.id, '01920000-0000-7000-8000-0000000040aa');
  });

  test('deux exemplaires d un code ne font plus planter la descente',
      () async {
    final now = DateTime.now().toUtc();
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: newId(), createdAt: now, updatedAt: now,
            code: 'ECONOME', label: 'Econome',
          ),
        );
    await AgentRepository(db).applyServerRole({
      'id': _econome,
      'code': 'ECONOME',
      'label': 'Econome',
      'permissions': ['stock.read'],
    });
  });
}
