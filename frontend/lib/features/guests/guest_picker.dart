/// Choisir ou creer un client, sans quitter l'ecran en cours.
///
/// Concu pour le cas le plus courant d'une reception : le telephone sonne,
/// quelqu'un veut une chambre. Le receptionniste tape le nom qu'on lui donne.
/// S'il existe, il le choisit ; sinon il le cree a la volee, avec le strict
/// minimum — nom, prenom, telephone.
///
/// Le reste de la fiche se remplit a l'arrivee, quand le client est devant le
/// comptoir avec sa piece d'identite. C'est d'ailleurs ce que demande le
/// cahier des charges : la piece est exigee au check-in (F1.2), pas a la
/// reservation. Au telephone, on a un nom et un numero, rien d'autre.
///
/// La version precedente imposait de sortir du formulaire, d'aller creer la
/// fiche dans le module Clients, puis de tout ressaisir : six navigations et
/// une saisie perdue pendant que le client attend.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

class GuestPicker extends ConsumerStatefulWidget {
  const GuestPicker({
    super.key,
    required this.selectedId,
    required this.onSelected,
  });

  final String? selectedId;
  final void Function(String? guestId) onSelected;

  @override
  ConsumerState<GuestPicker> createState() => _GuestPickerState();
}

class _GuestPickerState extends ConsumerState<GuestPicker> {
  final _search = TextEditingController();
  String _query = '';
  GuestRow? _selected;

  @override
  void initState() {
    super.initState();
    if (widget.selectedId != null) _loadInitial(widget.selectedId!);
  }

  Future<void> _loadInitial(String id) async {
    final guest = await ref.read(guestRepositoryProvider).byId(id);
    if (mounted) setState(() => _selected = guest);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _choose(GuestRow guest) {
    setState(() {
      _selected = guest;
      _query = '';
      _search.clear();
    });
    widget.onSelected(guest.id);
  }

  void _clear() {
    setState(() => _selected = null);
    widget.onSelected(null);
  }

  Future<void> _createFromSearch() async {
    final created = await showDialog<GuestRow>(
      context: context,
      builder: (_) => _QuickGuestDialog(initialText: _query),
    );
    if (created != null) _choose(created);
  }

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    if (_selected != null) {
      return _SelectedGuest(guest: _selected!, onClear: _clear);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          autofocus: false,
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            labelText: 'Client',
            hintText: 'Taper un nom, un prenom ou un telephone…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _query = '';
                      _search.clear();
                    }),
                  ),
          ),
          style: const TextStyle(fontSize: 18),
        ),
        if (_query.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          _Results(
            query: _query,
            onChoose: _choose,
            onCreate: _createFromSearch,
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              'Un habitue ? Tapez son nom. Un nouveau ? Tapez-le aussi, '
              'vous pourrez creer sa fiche sans quitter cet ecran.',
              style: TextStyle(fontSize: 15, color: schema.outline),
            ),
          ),
      ],
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({
    required this.query,
    required this.onChoose,
    required this.onCreate,
  });

  final String query;
  final void Function(GuestRow) onChoose;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schema = Theme.of(context).colorScheme;
    final results = ref.watch(guestSearchResultsProvider(query));

    return results.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('Lecture impossible : $e'),
      data: (guests) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (guests.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                border: Border.all(color: schema.outlineVariant),
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: guests.length,
                itemBuilder: (_, i) {
                  final g = guests[i];
                  return ListTile(
                    title: Text(
                      '${g.lastName.toUpperCase()} ${g.firstName}',
                      style: const TextStyle(fontSize: 17),
                    ),
                    subtitle: Text(
                      [g.code, if (g.phone != null) g.phone!].join(' · '),
                      style: TextStyle(fontSize: 14, color: schema.outline),
                    ),
                    onTap: () => onChoose(g),
                  );
                },
              ),
            ),
          const SizedBox(height: 10),
          // Toujours visible, meme quand des resultats existent : deux clients
          // peuvent porter le meme nom, et le receptionniste sait lequel est
          // au bout du fil, pas l'application.
          OutlinedButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.person_add_alt),
            label: Text(
              guests.isEmpty
                  ? 'Aucun resultat — creer « $query »'
                  : 'Ce n\'est aucun de ceux-la — creer « $query »',
            ),
          ),
        ],
      ),
    );
  }
}

/// Resultats de recherche, pour une saisie donnee.
final guestSearchResultsProvider =
    StreamProvider.family<List<GuestRow>, String>((ref, query) {
      return ref.watch(guestRepositoryProvider).watchGuests(search: query);
    });

class _SelectedGuest extends StatelessWidget {
  const _SelectedGuest({required this.guest, required this.onClear});

  final GuestRow guest;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: schema.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: schema.primary.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: schema.primaryContainer,
            child: Icon(Icons.person, color: schema.onPrimaryContainer),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${guest.lastName.toUpperCase()} ${guest.firstName}',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  [
                    guest.code,
                    if (guest.phone != null) guest.phone!,
                  ].join(' · '),
                  style: TextStyle(fontSize: 15, color: schema.outline),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Changer'),
          ),
        ],
      ),
    );
  }
}

/// Creation minimale : ce qu'on obtient au telephone, et rien de plus.
class _QuickGuestDialog extends ConsumerStatefulWidget {
  const _QuickGuestDialog({required this.initialText});

  final String initialText;

  @override
  ConsumerState<_QuickGuestDialog> createState() => _QuickGuestDialogState();
}

class _QuickGuestDialogState extends ConsumerState<_QuickGuestDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  final _phone = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Pre-remplissage depuis ce qui a ete tape : « Marc Dupont » donne prenom
    // Marc, nom Dupont ; un seul mot part dans le nom, le champ le plus
    // souvent renseigne. Le receptionniste corrige en un geste si besoin.
    final mots = widget.initialText.trim().split(RegExp(r'\s+'));
    if (mots.length >= 2) {
      _firstName = TextEditingController(text: mots.first);
      _lastName = TextEditingController(text: mots.sublist(1).join(' '));
    } else {
      _firstName = TextEditingController();
      _lastName = TextEditingController(text: mots.first);
    }
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final guest = await ref
        .read(guestRepositoryProvider)
        .create(
          firstName: _firstName.text,
          lastName: _lastName.text,
          phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
          createdBy: ref.read(sessionProvider).agent?.id,
        );

    if (mounted) Navigator.of(context).pop(guest);
  }

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Nouveau client'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _firstName,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Prenom'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lastName,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Nom'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Requis' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Telephone',
                  helperText: 'Facultatif, mais precieux pour rappeler',
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Piece d\'identite, nationalite et adresse se saisissent '
                'a l\'arrivee, depuis le module Clients.',
                style: TextStyle(fontSize: 14, color: schema.outline),
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
          onPressed: _busy ? null : _save,
          child: const Text('Creer et choisir'),
        ),
      ],
    );
  }
}
