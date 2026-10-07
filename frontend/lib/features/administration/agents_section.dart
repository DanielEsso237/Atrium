/// Les agents : creer, attribuer un role et des points de vente, desactiver.
///
/// Jamais de suppression : le travail passe d'un agent lui reste attribue.
/// Le PIN ne se saisit qu'a la creation et ne se relit jamais -- la tablette
/// n'en garde aucune copie.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/repositories/agent_repository.dart';
import '../../data/repositories/repository_providers.dart';

final _agents = StreamProvider<List<AgentView>>(
  (ref) => ref.watch(agentRepositoryProvider).watchAgents(),
);

final _roles = FutureProvider<List<RoleRow>>(
  (ref) => ref.watch(agentRepositoryProvider).roles(),
);

final _pointsDeVente = StreamProvider<List<OutletRow>>(
  (ref) => ref.watch(outletRepositoryProvider).watchAll(),
);

class AgentsSection extends ConsumerWidget {
  const AgentsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(_agents);
    final roles = ref.watch(_roles).value ?? const <RoleRow>[];
    final points = ref.watch(_pointsDeVente).value ?? const <OutletRow>[];

    String libelleRole(String code) =>
        roles.where((r) => r.code == code).firstOrNull?.label ?? code;
    String libellePoint(String id) =>
        points.where((o) => o.id == id).firstOrNull?.label ?? '…';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(child: Eyebrow('Agents')),
            PillButton(
              label: 'Nouvel agent',
              icon: PhosphorIconsLight.userPlus,
              tone: PillTone.accent,
              compact: true,
              onPressed: () => _ouvrir(context),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ...agents.when(
          loading: () => [const Center(child: CircularProgressIndicator())],
          error: (e, _) => [Text('Lecture impossible : $e')],
          data: (liste) => [
            for (final a in liste)
              _LigneAgent(
                agent: a,
                role: a.roleCodes.map(libelleRole).join(', '),
                points: a.outletIds.isEmpty
                    ? 'Tous les points de vente'
                    : a.outletIds.map(libellePoint).join(', '),
                onTap: () => _ouvrir(context, existant: a),
              ),
          ],
        ),
      ],
    );
  }

  void _ouvrir(BuildContext context, {AgentView? existant}) {
    showDialog<void>(
      context: context,
      builder: (_) => _AgentDialog(existant: existant),
    );
  }
}

class _LigneAgent extends StatelessWidget {
  const _LigneAgent({
    required this.agent,
    required this.role,
    required this.points,
    required this.onTap,
  });

  final AgentView agent;
  final String role;
  final String points;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final u = agent.user;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Monogram('${u.firstName} ${u.lastName}', size: 42),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${u.firstName} ${u.lastName}'.trim(),
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: u.isActive ? p.text : p.textSecondary,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: LigneCode(
                          u.employeeCode,
                          detail:
                              '${role.isEmpty ? 'sans rôle' : role}, $points',
                        ),
                      ),
                    ],
                  ),
                ),
                if (!u.isActive) const Tag('Désactivé'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AgentDialog extends ConsumerStatefulWidget {
  const _AgentDialog({this.existant});

  final AgentView? existant;

  @override
  ConsumerState<_AgentDialog> createState() => _AgentDialogState();
}

class _AgentDialogState extends ConsumerState<_AgentDialog> {
  late final _prenom = TextEditingController(
    text: widget.existant?.user.firstName,
  );
  late final _nom = TextEditingController(text: widget.existant?.user.lastName);
  late final _code = TextEditingController(
    text: widget.existant?.user.employeeCode,
  );
  final _pin = TextEditingController();
  late String? _role = widget.existant?.roleCodes.firstOrNull;
  late final Set<String> _points = {...?widget.existant?.outletIds};
  late bool _actif = widget.existant?.user.isActive ?? true;
  bool _busy = false;

  bool get _creation => widget.existant == null;

  /// Le role des commandes (restaurant, bar, boite de nuit...) : le seul
  /// qui se rattache a des points de vente.
  bool get _commandes => _role == roleCommandes;

  @override
  void dispose() {
    for (final c in [_prenom, _nom, _code, _pin]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _enregistrer() async {
    final role = _role;
    if (role == null) {
      _dire('Choisissez un rôle.');
      return;
    }
    setState(() => _busy = true);
    final depot = ref.read(agentRepositoryProvider);
    // Seul un agent des commandes a des points de vente ; les autres n'en
    // envoient aucun.
    final points = _commandes ? _points.toList() : <String>[];
    try {
      if (_creation) {
        await depot.create(
          employeeCode: _code.text,
          firstName: _prenom.text,
          lastName: _nom.text,
          pin: _pin.text.trim(),
          roleCode: role,
          outletIds: points,
        );
      } else {
        await depot.update(
          id: widget.existant!.user.id,
          firstName: _prenom.text,
          lastName: _nom.text,
          isActive: _actif,
          roleCode: role,
          outletIds: points,
        );
        // Un PIN saisi ici remplace celui que l'agent a oublie.
        if (_pin.text.trim().isNotEmpty) {
          await depot.resetPin(
            id: widget.existant!.user.id,
            pin: _pin.text.trim(),
          );
        }
      }
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _dire(e.message);
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _dire(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final roles = ref.watch(_roles).value ?? const <RoleRow>[];
    final points = ref.watch(_pointsDeVente).value ?? const <OutletRow>[];
    final p = AtriumPalette.current;

    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.user, size: 30),
      title: Text(_creation ? 'Nouvel agent' : 'Agent'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _prenom,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Prénom'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _nom,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Nom'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _code,
                      enabled: _creation,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Code agent',
                        helperText: 'Pour se connecter',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(8),
                      ],
                      // A la modification, le PIN ne se relit jamais : on en
                      // donne un nouveau, seulement si l'agent l'a oublie.
                      decoration: InputDecoration(
                        labelText: _creation ? 'PIN' : 'Nouveau PIN',
                        helperText: _creation
                            ? '4 à 8 chiffres'
                            : 'Seulement en cas d’oubli',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Rôle'),
                items: [
                  for (final r in roles)
                    DropdownMenuItem(value: r.code, child: Text(r.label)),
                ],
                // Changer de role vide les points de vente coches : ils ne
                // valent que pour les commandes.
                onChanged: (v) => setState(() {
                  _role = v;
                  if (!_commandes) _points.clear();
                }),
              ),
              if (_commandes) ...[
                const SizedBox(height: 16),
                Text(
                  'Points de vente',
                  style: TextStyle(fontSize: 14, color: p.textSecondary),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in points)
                      FilterChip(
                        label: Text(o.label),
                        selected: _points.contains(o.id),
                        onSelected: (v) => setState(
                          () => v ? _points.add(o.id) : _points.remove(o.id),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _points.isEmpty
                      ? 'Aucun coché : l’agent voit tous les points de vente.'
                      : 'L’agent ne verra que ceux-là dans l’écran Commande.',
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
              ],
              if (_creation) ...[
                const SizedBox(height: 12),
                Text(
                  'Un nouvel agent se connecte en ligne. La connexion hors '
                  'ligne suivra.',
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
              ] else
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _actif,
                  onChanged: (v) => setState(() => _actif = v),
                  title: const Text('Actif'),
                  subtitle: const Text(
                    'Désactivé, il ne peut plus se connecter. Son travail '
                    'passé lui reste attribué.',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _busy ? null : _enregistrer,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
