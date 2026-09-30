/// Le plafond de consommation a credit de chaque client.
///
/// Le patron l'a dit le 29 septembre : c'est l'administrateur qui le fixe.
/// Au-dela, la consommation est refusee -- pas de contournement la nuit,
/// le barman refuse. `0` veut dire « pas de limite ».
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

final _recherche = NotifierProvider<_Recherche, String>(_Recherche.new);

class _Recherche extends Notifier<String> {
  @override
  String build() => '';

  void update(String v) => state = v;
}

final _clients = StreamProvider<List<GuestRow>>(
  (ref) => ref
      .watch(guestRepositoryProvider)
      .watchGuests(search: ref.watch(_recherche)),
);

/// « Pas de limite » pour 0, le montant sinon.
String libellePlafond(int plafond) =>
    plafond == 0 ? 'Pas de limite' : formatAmount(plafond);

class CreditLimitsSection extends ConsumerWidget {
  const CreditLimitsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clients = ref.watch(_clients);
    final p = AtriumPalette.current;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Eyebrow('Plafond de consommation à crédit'),
        const SizedBox(height: 6),
        Text(
          '0 veut dire « pas de limite ». Au-delà du plafond, la consommation '
          'est refusée.',
          style: TextStyle(fontSize: 14, color: p.textSecondary),
        ),
        const SizedBox(height: 14),
        TextField(
          onChanged: ref.read(_recherche.notifier).update,
          decoration: const InputDecoration(
            hintText: 'Rechercher un client…',
            prefixIcon: Icon(PhosphorIconsLight.magnifyingGlass),
          ),
        ),
        const SizedBox(height: 14),
        ...clients.when(
          loading: () => [const Center(child: CircularProgressIndicator())],
          error: (e, _) => [Text('Lecture impossible : $e')],
          data: (liste) => [
            for (final g in liste)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(16),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    title: Text('${g.lastName.toUpperCase()} ${g.firstName}'),
                    subtitle: Text(g.code),
                    trailing: Text(
                      libellePlafond(g.creditLimit),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: g.creditLimit == 0 ? p.textSecondary : p.text,
                      ),
                    ),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (_) => _PlafondDialog(client: g),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _PlafondDialog extends ConsumerStatefulWidget {
  const _PlafondDialog({required this.client});

  final GuestRow client;

  @override
  ConsumerState<_PlafondDialog> createState() => _PlafondDialogState();
}

class _PlafondDialogState extends ConsumerState<_PlafondDialog> {
  late final _montant = TextEditingController(
    text: '${widget.client.creditLimit}',
  );
  bool _busy = false;

  @override
  void dispose() {
    _montant.dispose();
    super.dispose();
  }

  Future<void> _enregistrer() async {
    final plafond = int.tryParse(_montant.text.trim());
    if (plafond == null) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(guestRepositoryProvider)
          .setCreditLimit(
            id: widget.client.id,
            creditLimit: plafond,
            updatedBy: ref.read(sessionProvider).agent?.id,
          );
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.client;
    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.scales, size: 30),
      title: Text('Plafond · ${g.firstName} ${g.lastName}'.trim()),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _montant,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Plafond',
            suffixText: 'FCFA',
            helperText: '0 = pas de limite',
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
