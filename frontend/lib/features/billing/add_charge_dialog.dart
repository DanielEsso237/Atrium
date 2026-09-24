/// Porter une consommation a l'ardoise (F1.4).
///
/// Ouverte depuis la fiche de chambre, pendant que le client est encore au
/// comptoir ou au telephone. La saisie doit tenir en quelques secondes : d'ou
/// les raccourcis pour ce qui se vend dix fois par jour, et un formulaire
/// libre pour le reste.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

/// Ce qui se vend le plus souvent, pre-rempli en un clic.
///
/// Les prix sont ceux de l'hotel et se corrigent avant validation : un
/// raccourci fait gagner du temps, il ne decide pas a la place de l'agent.
typedef _Raccourci = (String libelle, ChargeCategory categorie, int prix);

const _raccourcis = <_Raccourci>[
  ('Petit dejeuner', ChargeCategory.FNB, 5000),
  ('Minibar', ChargeCategory.MINIBAR, 3000),
  ('Blanchisserie', ChargeCategory.LAUNDRY, 7500),
  ('Room service', ChargeCategory.FNB, 15000),
];

/// Propose de porter une charge sur `folioId`.
Future<bool> showAddChargeDialog(
  BuildContext context, {
  required String folioId,
  required String guestName,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _AddChargeDialog(folioId: folioId, guestName: guestName),
  );
  return ok ?? false;
}

class _AddChargeDialog extends ConsumerStatefulWidget {
  const _AddChargeDialog({required this.folioId, required this.guestName});

  final String folioId;
  final String guestName;

  @override
  ConsumerState<_AddChargeDialog> createState() => _AddChargeDialogState();
}

class _AddChargeDialogState extends ConsumerState<_AddChargeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _price = TextEditingController();
  ChargeCategory _category = ChargeCategory.FNB;
  int _quantity = 1;
  bool _busy = false;

  @override
  void dispose() {
    _label.dispose();
    _price.dispose();
    super.dispose();
  }

  int get _unitPrice => int.tryParse(_price.text.trim()) ?? 0;
  int get _total => _unitPrice * _quantity;

  void _applyShortcut(_Raccourci r) {
    setState(() {
      _label.text = r.$1;
      _category = r.$2;
      _price.text = '${r.$3}';
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    await ref
        .read(folioRepositoryProvider)
        .addCharge(
          folioId: widget.folioId,
          category: _category,
          label: _label.text,
          unitPrice: _unitPrice,
          quantity: _quantity,
          postedBy: ref.read(sessionProvider).agent?.id,
        );

    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${formatAmount(_total)} porte a l\'ardoise de ${widget.guestName}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text('Consommation — ${widget.guestName}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in _raccourcis)
                      ActionChip(
                        label: Text(r.$1),
                        onPressed: () => _applyShortcut(r),
                      ),
                  ],
                ),
                const SizedBox(height: 18),

                TextFormField(
                  controller: _label,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Libelle',
                    hintText: 'Ce qui apparaitra sur la facture',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Requis' : null,
                ),
                const SizedBox(height: 12),

                DropdownButtonFormField<ChargeCategory>(
                  initialValue: _category,
                  decoration: const InputDecoration(labelText: 'Categorie'),
                  items: [
                    for (final c in ChargeCategory.values)
                      DropdownMenuItem(value: c, child: Text(c.name)),
                  ],
                  onChanged: (v) =>
                      setState(() => _category = v ?? ChargeCategory.FNB),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _price,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Prix unitaire (FCFA)',
                        ),
                        validator: (v) {
                          final n = int.tryParse((v ?? '').trim());
                          if (n == null || n <= 0) return 'Montant invalide';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 16),
                    _Quantity(
                      value: _quantity,
                      onChange: (v) => setState(() => _quantity = v),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: schema.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Text('Total', style: TextStyle(fontSize: 17)),
                      const Spacer(),
                      Text(
                        formatAmount(_total),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Porter a l\'ardoise'),
        ),
      ],
    );
  }
}

class _Quantity extends StatelessWidget {
  const _Quantity({required this.value, required this.onChange});

  final int value;
  final void Function(int) onChange;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: schema.outline),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            iconSize: 26,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: value > 1 ? () => onChange(value - 1) : null,
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            iconSize: 26,
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => onChange(value + 1),
          ),
        ],
      ),
    );
  }
}
