/// Les roles et leurs permissions cochees.
///
/// Un role ne se cree pas ici : les roles viennent du serveur. On y ajuste
/// ce que chacun peut faire. La derniere permission d'administration ne peut
/// pas etre retiree (voir `RoleRepository.setPermissions`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../data/local/database.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/role_repository.dart';

final _roles = StreamProvider<List<RoleView>>(
  (ref) => ref.watch(roleRepositoryProvider).watchRoles(),
);

final _catalogue = FutureProvider<List<PermissionRow>>(
  (ref) => ref.watch(roleRepositoryProvider).permissions(),
);

class RolesSection extends ConsumerWidget {
  const RolesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roles = ref.watch(_roles);
    final catalogue = ref.watch(_catalogue).value ?? const <PermissionRow>[];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Eyebrow('Rôles et permissions'),
        const SizedBox(height: 14),
        ...roles.when(
          loading: () => [const Center(child: CircularProgressIndicator())],
          error: (e, _) => [Text('Lecture impossible : $e')],
          data: (liste) => [
            for (final r in liste)
              _CarteRole(
                key: ValueKey('${r.role.id}:${r.permissions.length}'),
                vue: r,
                catalogue: catalogue,
              ),
          ],
        ),
      ],
    );
  }
}

class _CarteRole extends ConsumerStatefulWidget {
  const _CarteRole({super.key, required this.vue, required this.catalogue});

  final RoleView vue;
  final List<PermissionRow> catalogue;

  @override
  ConsumerState<_CarteRole> createState() => _CarteRoleState();
}

class _CarteRoleState extends ConsumerState<_CarteRole> {
  late Set<String> _cochees = {...widget.vue.permissions};
  bool _busy = false;

  bool get _modifie =>
      _cochees.length != widget.vue.permissions.length ||
      !_cochees.containsAll(widget.vue.permissions);

  Future<void> _enregistrer() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(roleRepositoryProvider)
          .setPermissions(roleId: widget.vue.role.id, codes: _cochees);
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _cochees = {...widget.vue.permissions};
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final parModule = <String, List<PermissionRow>>{};
    for (final perm in widget.catalogue) {
      parModule.putIfAbsent(perm.module, () => []).add(perm);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          title: Text(
            widget.vue.role.label,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '${widget.vue.role.code}, ${widget.vue.permissions.length} '
            'permission${widget.vue.permissions.length > 1 ? 's' : ''}',
            style: TextStyle(fontSize: 13.5, color: p.textSecondary),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            for (final MapEntry(key: module, value: perms) in parModule.entries)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 2),
                    child: Text(
                      module.toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                  for (final perm in perms)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _cochees.contains(perm.code),
                      onChanged: _busy
                          ? null
                          : (v) => setState(
                              () => v == true
                                  ? _cochees.add(perm.code)
                                  : _cochees.remove(perm.code),
                            ),
                      title: Text(perm.label),
                      subtitle: Text(perm.code),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: PillButton(
                label: 'Enregistrer',
                tone: PillTone.accent,
                compact: true,
                onPressed: _busy || !_modifie ? null : _enregistrer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
