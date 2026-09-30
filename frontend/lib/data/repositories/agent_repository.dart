/// Les agents : creation, modification, desactivation depuis l'administration,
/// et enregistrement des agents tels que le serveur les decrit.
///
/// Un agent ne se supprime pas : son travail passe (encaissements, menages,
/// check-ins) lui reste attribue. Desactive, il ne peut plus se connecter.
///
/// Le PIN n'est jamais garde sur la tablette. Il part une fois vers le
/// serveur, qui le hache, puis est efface de la file d'envoi (voir
/// `OutboxSender._appliquerReponse`). Consequence assumee : un agent cree ici
/// se connecte **en ligne** ; la connexion hors ligne des nouveaux agents est
/// un ticket a part.
library;

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// Un agent tel que l'administration le montre.
class AgentView {
  const AgentView({
    required this.user,
    required this.roleCodes,
    required this.outletIds,
  });

  final UserRow user;
  final List<String> roleCodes;

  /// Vide : tous les points de vente.
  final List<String> outletIds;
}

class AgentRepository with OutboxWriter {
  AgentRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  /// Les agents, desactives compris : c'est ici qu'on les reactive.
  Stream<List<AgentView>> watchAgents() {
    return db
        .customSelect(
          '''
      SELECT u.id,
             (SELECT GROUP_CONCAT(r.code, ',') FROM user_roles ur
                JOIN roles r ON r.id = ur.role_id
               WHERE ur.user_id = u.id) AS roles,
             (SELECT GROUP_CONCAT(uo.outlet_id, ',') FROM user_outlets uo
               WHERE uo.user_id = u.id) AS outlets
        FROM users u
       WHERE u.deleted_at IS NULL
       ORDER BY u.is_active DESC, u.last_name, u.first_name
      ''',
          readsFrom: {db.users, db.userRoles, db.roles, db.userOutlets},
        )
        .watch()
        .asyncMap((lignes) async {
          final users = {
            for (final u in await db.select(db.users).get()) u.id: u,
          };
          return [
            for (final l in lignes)
              if (users[l.read<String>('id')] case final u?)
                AgentView(
                  user: u,
                  roleCodes: _liste(l.read<String?>('roles')),
                  outletIds: _liste(l.read<String?>('outlets')),
                ),
          ];
        });
  }

  /// Les roles que l'administration peut attribuer.
  Future<List<RoleRow>> roles() => (db.select(db.roles)
        ..where((r) => r.deletedAt.isNull() & r.isActive.equals(true))
        ..orderBy([(r) => OrderingTerm(expression: r.label)]))
      .get();

  /// Cree un agent. Le PIN part vers le serveur et n'est pas garde ici.
  Future<UserRow> create({
    required String employeeCode,
    required String firstName,
    required String lastName,
    required String pin,
    required String roleCode,
    List<String> outletIds = const [],
  }) async {
    final code = employeeCode.trim().toUpperCase();
    await _verifier(
      code: code,
      firstName: firstName,
      lastName: lastName,
      roleCode: roleCode,
    );
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      throw StateError('Le PIN compte de 4 à 8 chiffres.');
    }
    final id = newId();
    final now = DateTime.now().toUtc();

    return writeAndEnqueue(
      table: 'users',
      id: id,
      operation: SyncOp.INSERT,
      payload: {
        'id': id,
        'employee_code': code,
        'first_name': firstName.trim(),
        'last_name': lastName.trim(),
        'pin': pin,
        'role_codes': [roleCode],
        'outlet_ids': outletIds,
      },
      action: () async {
        await db
            .into(db.users)
            .insert(
              UsersCompanion.insert(
                id: id,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                employeeCode: code,
                firstName: firstName.trim(),
                lastName: lastName.trim(),
                mustChangePassword: const Value(false),
                syncState: const Value(SyncState.pending),
              ),
            );
        await _rattacher(id, [roleCode], outletIds);
        return _byId(id);
      },
    );
  }

  /// Modifie un agent ; `isActive: false` le desactive sans rien effacer.
  Future<UserRow> update({
    required String id,
    required String firstName,
    required String lastName,
    required bool isActive,
    required String roleCode,
    List<String> outletIds = const [],
  }) async {
    final actuel = await _byId(id);
    await _verifier(
      code: actuel.employeeCode,
      firstName: firstName,
      lastName: lastName,
      roleCode: roleCode,
      sauf: id,
    );
    final now = DateTime.now().toUtc();

    return writeAndEnqueue(
      table: 'users',
      id: id,
      operation: SyncOp.UPDATE,
      payload: {
        'id': id,
        'first_name': firstName.trim(),
        'last_name': lastName.trim(),
        'is_active': isActive,
        'role_codes': [roleCode],
        'outlet_ids': outletIds,
      },
      action: () async {
        await (db.update(db.users)..where((u) => u.id.equals(id))).write(
          UsersCompanion(
            firstName: Value(firstName.trim()),
            lastName: Value(lastName.trim()),
            isActive: Value(isActive),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
        await _rattacher(id, [roleCode], outletIds);
        return _byId(id);
      },
    );
  }

  /// Enregistre un agent tel que le serveur le decrit (`UserOut`) : son
  /// identite, ses roles **avec leurs permissions**, ses points de vente.
  ///
  /// C'est ce qui donne ses droits a un agent que cette tablette ne
  /// connaissait pas : les ecrans et le routeur lisent les droits en local.
  /// Les empreintes de secret ne sont pas touchees -- le serveur ne les
  /// envoie pas. Un agent modifie ici et pas encore remonte n'est pas
  /// ecrase : la version locale fait foi jusqu'a sa remontee.
  Future<void> applyServerAgent(Map<String, dynamic> json) async {
    final id = json['id'] as String?;
    final code = json['employee_code'] as String?;
    if (id == null || code == null) return;

    await db.transaction(() async {
      final local = await (db.select(
        db.users,
      )..where((u) => u.id.equals(id))).getSingleOrNull();
      if (local?.syncState == SyncState.pending) return;

      final now = DateTime.now().toUtc();
      await db
          .into(db.users)
          .insertOnConflictUpdate(
            UsersCompanion.insert(
              id: id,
              createdAt: local?.createdAt ?? now,
              updatedAt: now,
              hotelId: hotelId,
              employeeCode: code.toUpperCase(),
              firstName: (json['first_name'] as String?) ?? '',
              lastName: (json['last_name'] as String?) ?? code,
              email: Value(json['email'] as String?),
              isActive: Value(json['is_active'] != false),
              syncState: const Value(SyncState.synced),
            ),
          );

      final codesRoles = <String>[];
      for (final r in (json['roles'] as List? ?? const [])) {
        if (r is! Map || r['code'] is! String) continue;
        final roleId = await _role(
          r['code'] as String,
          (r['label'] as String?) ?? r['code'] as String,
        );
        await _permissions(roleId, [
          for (final p in (r['permissions'] as List? ?? const []))
            if (p is String) p,
        ]);
        codesRoles.add(r['code'] as String);
      }
      await _rattacher(id, codesRoles, [
        for (final o in (json['outlet_ids'] as List? ?? const []))
          if (o is String) o,
      ]);
    });
  }

  /// Remplace les roles et les points de vente d'un agent.
  Future<void> _rattacher(
    String userId,
    List<String> roleCodes,
    List<String> outletIds,
  ) async {
    await (db.delete(db.userRoles)..where((ur) => ur.userId.equals(userId)))
        .go();
    for (final code in roleCodes) {
      final role = await (db.select(
        db.roles,
      )..where((r) => r.code.equals(code))).getSingleOrNull();
      if (role == null) continue;
      await db
          .into(db.userRoles)
          .insertOnConflictUpdate(
            UserRolesCompanion.insert(userId: userId, roleId: role.id),
          );
    }
    await (db.delete(
      db.userOutlets,
    )..where((uo) => uo.userId.equals(userId))).go();
    for (final o in outletIds.toSet()) {
      await db
          .into(db.userOutlets)
          .insert(UserOutletsCompanion.insert(userId: userId, outletId: o));
    }
  }

  /// Le role de ce code, cree s'il n'existe pas encore sur la tablette.
  Future<String> _role(String code, String label) async {
    final existant = await (db.select(
      db.roles,
    )..where((r) => r.code.equals(code))).getSingleOrNull();
    if (existant != null) return existant.id;
    final id = newId();
    final now = DateTime.now().toUtc();
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            code: code,
            label: label,
            syncState: const Value(SyncState.synced),
          ),
        );
    return id;
  }

  /// Aligne les permissions d'un role sur celles du serveur.
  Future<void> _permissions(String roleId, List<String> codes) async {
    await (db.delete(
      db.rolePermissions,
    )..where((rp) => rp.roleId.equals(roleId))).go();
    for (final code in codes.toSet()) {
      var permission = await (db.select(
        db.permissions,
      )..where((p) => p.code.equals(code))).getSingleOrNull();
      if (permission == null) {
        final now = DateTime.now().toUtc();
        await db
            .into(db.permissions)
            .insert(
              PermissionsCompanion.insert(
                id: newId(),
                createdAt: now,
                updatedAt: now,
                code: code,
                label: code,
                module: code.split('.').first,
              ),
            );
        permission = await (db.select(
          db.permissions,
        )..where((p) => p.code.equals(code))).getSingle();
      }
      await db
          .into(db.rolePermissions)
          .insertOnConflictUpdate(
            RolePermissionsCompanion.insert(
              roleId: roleId,
              permissionId: permission.id,
            ),
          );
    }
  }

  /// Refuse ici ce que le serveur refuserait : un refus par la file la
  /// bloquerait, avec tout ce qui attend derriere.
  Future<void> _verifier({
    required String code,
    required String firstName,
    required String lastName,
    required String roleCode,
    String? sauf,
  }) async {
    if (code.isEmpty || code.length > 32) {
      throw StateError('Le code agent est obligatoire (32 caractères au plus).');
    }
    if (firstName.trim().isEmpty || lastName.trim().isEmpty) {
      throw StateError('Le nom et le prénom sont obligatoires.');
    }
    final role = await (db.select(
      db.roles,
    )..where((r) => r.code.equals(roleCode))).getSingleOrNull();
    if (role == null) throw StateError('Choisissez un rôle.');
    final pris = await (db.select(db.users)..where(
          (u) =>
              u.employeeCode.equals(code) &
              (sauf == null ? const Constant(true) : u.id.equals(sauf).not()),
        ))
        .get();
    if (pris.isNotEmpty) {
      throw StateError('Le code « $code » est déjà utilisé.');
    }
  }

  Future<UserRow> _byId(String id) =>
      (db.select(db.users)..where((u) => u.id.equals(id))).getSingle();

  static List<String> _liste(String? csv) =>
      csv == null || csv.isEmpty ? const [] : csv.split(',');
}
