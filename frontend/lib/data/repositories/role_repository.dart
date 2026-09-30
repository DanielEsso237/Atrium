/// Les roles et leurs permissions, depuis l'administration.
///
/// La regle de la carte : on ne retire pas la derniere permission
/// d'administration. Un hotel sans aucun agent actif portant `users.write`
/// ne se repare pas depuis l'application. Le serveur la tient
/// (`PUT /roles/{code}/permissions`, 409) ; la tablette la verifie avant
/// d'ecrire, avec le meme calcul -- un refus par la file la bloquerait.
library;

import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// La permission sans laquelle plus personne n'administre l'hotel.
const adminPermission = 'users.write';

/// Un role et les codes de ses permissions.
class RoleView {
  const RoleView({required this.role, required this.permissions});

  final RoleRow role;
  final Set<String> permissions;
}

class RoleRepository with OutboxWriter {
  RoleRepository(this.db);

  @override
  final AtriumDatabase db;

  Stream<List<RoleView>> watchRoles() {
    return db
        .customSelect(
          '''
      SELECT r.id AS role_id, p.code AS code
        FROM roles r
        LEFT JOIN role_permissions rp ON rp.role_id = r.id
        LEFT JOIN permissions p ON p.id = rp.permission_id
       WHERE r.deleted_at IS NULL
      ''',
          readsFrom: {db.roles, db.rolePermissions, db.permissions},
        )
        .watch()
        .asyncMap((lignes) async {
          final parRole = <String, Set<String>>{};
          for (final l in lignes) {
            final codes = parRole.putIfAbsent(l.read<String>('role_id'), () => {});
            final code = l.read<String?>('code');
            if (code != null) codes.add(code);
          }
          final roles = await (db.select(db.roles)
                ..where((r) => r.deletedAt.isNull())
                ..orderBy([(r) => OrderingTerm(expression: r.label)]))
              .get();
          return [
            for (final r in roles)
              RoleView(role: r, permissions: parRole[r.id] ?? const {}),
          ];
        });
  }

  /// Le catalogue des permissions, par module.
  Future<List<PermissionRow>> permissions() => (db.select(db.permissions)
        ..orderBy([
          (p) => OrderingTerm(expression: p.module),
          (p) => OrderingTerm(expression: p.code),
        ]))
      .get();

  /// L'hotel garderait-il un administrateur si ce role perdait `users.write` ?
  Future<bool> resteUnAdministrateurSans(String roleId) async {
    final r = await db
        .customSelect(
          '''
      SELECT 1 FROM users u
        JOIN user_roles ur ON ur.user_id = u.id
        JOIN role_permissions rp ON rp.role_id = ur.role_id
        JOIN permissions p ON p.id = rp.permission_id
       WHERE u.is_active = 1
         AND u.deleted_at IS NULL
         AND ur.role_id <> ?1
         AND p.code = ?2
       LIMIT 1
      ''',
          variables: [
            Variable.withString(roleId),
            Variable.withString(adminPermission),
          ],
        )
        .getSingleOrNull();
    return r != null;
  }

  /// Remplace les permissions d'un role.
  Future<void> setPermissions({
    required String roleId,
    required Set<String> codes,
  }) async {
    final role = await (db.select(
      db.roles,
    )..where((r) => r.id.equals(roleId))).getSingle();
    if (!codes.contains(adminPermission) &&
        !await resteUnAdministrateurSans(roleId)) {
      throw StateError(
        'Ce rôle porte la dernière permission d’administration : sans elle, '
        'plus personne ne pourrait administrer l’hôtel.',
      );
    }
    final catalogue = {
      for (final p in await db.select(db.permissions).get()) p.code: p.id,
    };
    final inconnues = codes.where((c) => !catalogue.containsKey(c));
    if (inconnues.isNotEmpty) {
      throw StateError('Permissions inconnues : ${inconnues.join(', ')}.');
    }
    final triees = codes.toList()..sort();

    await writeAndEnqueue(
      table: 'roles',
      id: roleId,
      operation: SyncOp.UPDATE,
      payload: {'id': roleId, 'code': role.code, 'permissions': triees},
      action: () async {
        await (db.delete(
          db.rolePermissions,
        )..where((rp) => rp.roleId.equals(roleId))).go();
        for (final c in triees) {
          await db
              .into(db.rolePermissions)
              .insert(
                RolePermissionsCompanion.insert(
                  roleId: roleId,
                  permissionId: catalogue[c]!,
                ),
              );
        }
        await (db.update(db.roles)..where((r) => r.id.equals(roleId))).write(
          RolesCompanion(
            updatedAt: Value(DateTime.now().toUtc()),
            syncState: const Value(SyncState.pending),
          ),
        );
      },
    );
  }
}
