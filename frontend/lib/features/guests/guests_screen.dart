/// Fichier clients (cahier des charges, F1.6).
///
/// Liste, recherche, creation, fiche et historique des sejours.
///
/// C'est le premier ecran ou la reception **ecrit**. La fiche part dans Drift
/// et dans la file d'attente en une seule transaction, sans attendre le
/// reseau : le client est enregistre meme si le Wi-Fi est tombe.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/guest_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

/// Texte saisi dans la barre de recherche.
///
/// Un `Notifier` et non un `StateProvider` : celui-ci a disparu en Riverpod 3.
class GuestSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final guestSearchProvider = NotifierProvider<GuestSearch, String>(
  GuestSearch.new,
);

final guestsProvider = StreamProvider<List<GuestRow>>((ref) {
  final search = ref.watch(guestSearchProvider);
  return ref.watch(guestRepositoryProvider).watchGuests(search: search);
});

class GuestsScreen extends ConsumerWidget {
  const GuestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guests = ref.watch(guestsProvider);
    final schema = Theme.of(context).colorScheme;

    return ModuleScaffold(
      title: 'Clients',
      action: FilledButton.icon(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const _NewGuestDialog(),
        ),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Nouveau client'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: TextField(
              onChanged: (v) =>
                  ref.read(guestSearchProvider.notifier).update(v),
              decoration: const InputDecoration(
                hintText: 'Rechercher un nom, un telephone, un code…',
                prefixIcon: Icon(Icons.search),
              ),
              style: const TextStyle(fontSize: 18),
            ),
          ),
          Expanded(
            child: guests.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Lecture impossible : $e')),
              data: (list) => list.isEmpty
                  ? Center(
                      child: Text(
                        'Aucun client ne correspond.',
                        style: TextStyle(fontSize: 18, color: schema.outline),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(24),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _GuestCard(guest: list[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GuestCard extends StatelessWidget {
  const _GuestCard({required this.guest});

  final GuestRow guest;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final initials =
        '${guest.firstName.isEmpty ? '' : guest.firstName[0]}'
        '${guest.lastName.isEmpty ? '' : guest.lastName[0]}';

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 12,
        ),
        leading: CircleAvatar(
          radius: 26,
          backgroundColor: schema.primaryContainer,
          child: Text(
            initials.toUpperCase(),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: schema.onPrimaryContainer,
            ),
          ),
        ),
        title: Text(
          '${guest.lastName.toUpperCase()} ${guest.firstName}',
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            guest.code,
            if (guest.phone != null) guest.phone!,
            if (guest.email != null) guest.email!,
          ].join(' · '),
          style: TextStyle(fontSize: 15, color: schema.outline),
        ),
        // Une fiche creee hors ligne se signale : la reception doit savoir ce
        // qui est deja connu du serveur et ce qui ne l'est pas encore.
        trailing: guest.syncState == SyncState.pending
            ? Tooltip(
                message: 'En attente de remontee au serveur',
                child: Icon(
                  Icons.cloud_upload_outlined,
                  size: 24,
                  color: schema.outline,
                ),
              )
            : const Icon(Icons.chevron_right, size: 28),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => FractionallySizedBox(
            heightFactor: 0.8,
            child: _GuestSheet(guest: guest),
          ),
        ),
      ),
    );
  }
}

class _GuestSheet extends ConsumerWidget {
  const _GuestSheet({required this.guest});

  final GuestRow guest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(guestRepositoryProvider);
    final schema = Theme.of(context).colorScheme;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF4F6F8),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${guest.lastName.toUpperCase()} ${guest.firstName}',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  iconSize: 30,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _Block(
                  title: 'Identite',
                  child: Column(
                    children: [
                      _Row(label: 'Code', value: guest.code),
                      _Row(label: 'Telephone', value: guest.phone ?? '—'),
                      _Row(label: 'Courriel', value: guest.email ?? '—'),
                      _Row(
                        label: 'Nationalite',
                        value: guest.nationality ?? '—',
                      ),
                      _Row(
                        label: 'Piece d\'identite',
                        value: guest.idDocumentNumber == null
                            ? '—'
                            : '${guest.idDocumentType?.name ?? ''} '
                                  '${guest.idDocumentNumber}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                FutureBuilder<List<GuestStay>>(
                  future: repo.stays(guest.id),
                  builder: (context, snap) {
                    final stays = snap.data ?? const <GuestStay>[];
                    return _Block(
                      title: 'Historique des sejours',
                      child: stays.isEmpty
                          ? Text(
                              'Aucun sejour enregistre.',
                              style: TextStyle(
                                fontSize: 17,
                                color: schema.outline,
                              ),
                            )
                          : Column(
                              children: [
                                for (final s in stays)
                                  _Row(
                                    label: s.reference,
                                    value:
                                        '${s.arrival} → ${s.departure} · '
                                        '${s.status}',
                                  ),
                              ],
                            ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NewGuestDialog extends ConsumerStatefulWidget {
  const _NewGuestDialog();

  @override
  ConsumerState<_NewGuestDialog> createState() => _NewGuestDialogState();
}

class _NewGuestDialogState extends ConsumerState<_NewGuestDialog> {
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _nationality = TextEditingController();
  final _documentNumber = TextEditingController();
  IdDocumentType? _documentType;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _firstName,
      _lastName,
      _phone,
      _email,
      _nationality,
      _documentNumber,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _vide(String? v) => v == null || v.trim().isEmpty ? null : v.trim();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final guest = await ref
        .read(guestRepositoryProvider)
        .create(
          firstName: _firstName.text,
          lastName: _lastName.text,
          phone: _vide(_phone.text),
          email: _vide(_email.text),
          nationality: _vide(_nationality.text),
          documentType: _documentType,
          documentNumber: _vide(_documentNumber.text),
          createdBy: ref.read(sessionProvider).agent?.id,
        );

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Fiche ${guest.code} creee — en attente de remontee.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nouveau client'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
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
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Requis' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _lastName,
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
                  decoration: const InputDecoration(labelText: 'Telephone'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Courriel'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nationality,
                  decoration: const InputDecoration(labelText: 'Nationalite'),
                ),
                const SizedBox(height: 12),
                // La piece d'identite est exigee a l'arrivee, pas a la
                // creation : une reservation par telephone se prend sans
                // piece sous les yeux.
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<IdDocumentType>(
                        initialValue: _documentType,
                        decoration: const InputDecoration(
                          labelText: 'Type de piece',
                        ),
                        items: [
                          for (final t in IdDocumentType.values)
                            DropdownMenuItem(value: t, child: Text(t.name)),
                        ],
                        onChanged: (v) => setState(() => _documentType = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _documentNumber,
                        decoration: const InputDecoration(labelText: 'Numero'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
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
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 170,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 17))),
      ],
    ),
  );
}
