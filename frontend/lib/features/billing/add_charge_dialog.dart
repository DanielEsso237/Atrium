/// Porter une consommation a l'ardoise (F1.4).
///
/// Ouverte depuis la fiche de chambre, pendant que le client est encore au
/// comptoir ou au telephone. La saisie doit tenir en quelques secondes : d'ou
/// les raccourcis pour ce qui se vend dix fois par jour, et un formulaire
/// libre pour le reste.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import 'charge_labels.dart';

/// Ce qui se vend le plus souvent, pre-rempli en un clic.
///
/// Les prix sont ceux de l'hotel et se corrigent avant validation : un
/// raccourci fait gagner du temps, il ne decide pas a la place de l'agent.
typedef _Raccourci = (String libelle, ChargeCategory categorie, int prix);

const _raccourcis = <_Raccourci>[
  ('Petit déjeuner', ChargeCategory.FNB, 5000),
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

    // Toute erreur remet le bouton en etat et se dit. Sinon l'ecran reste
    // fige sur un bouton grise sans rien expliquer, et l'agent croit que
    // l'application a plante -- c'est exactement ce qui s'est produit avec la
    // liaison de parametres de `customStatement`.
    try {
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Echec : $e')));
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "${formatAmount(_total)} porté à l'ardoise de ${widget.guestName}.",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;

    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.shoppingBagOpen, size: 32),
      title: Text('Consommation · ${widget.guestName}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Eyebrow('Raccourcis'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in _raccourcis)
                      _Raccourcis(raccourci: r, onTap: () => _applyShortcut(r)),
                  ],
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _label,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Libellé',
                    hintText: 'Ce qui apparaîtra sur la facture',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Requis' : null,
                ),
                const SizedBox(height: 16),
                const Eyebrow('Catégorie'),
                const SizedBox(height: 10),
                ChoiceTiles<ChargeCategory>(
                  selected: _category,
                  tileWidth: 118,
                  onChanged: (c) => setState(() => _category = c),
                  options: [
                    for (final c in ChargeCategory.values)
                      (c, chargeCategoryIcon(c), chargeCategoryLabel(c)),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _price,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Prix unitaire',
                          suffixText: 'FCFA',
                        ),
                        validator: (v) {
                          final n = int.tryParse((v ?? '').trim());
                          if (n == null || n <= 0) return 'Montant invalide';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    _Quantity(
                      value: _quantity,
                      onChange: (v) => setState(() => _quantity = v),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: p.isDark ? p.nightRaised : p.night,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Total',
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: p.onNightSoft,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        formatAmount(_total),
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8,
                          color: p.accent,
                          fontFeatures: tabularFigures,
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
          child: const Text("Porter à l'ardoise"),
        ),
      ],
    );
  }
}

class _Raccourcis extends StatelessWidget {
  const _Raccourcis({required this.raccourci, required this.onTap});

  final _Raccourci raccourci;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: p.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(chargeCategoryIcon(raccourci.$2), size: 20, color: p.accent),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    raccourci.$1,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                  Text(
                    formatAmount(raccourci.$3),
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 12,
                      color: p.textSecondary,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Quantity extends StatelessWidget {
  const _Quantity({required this.value, required this.onChange});

  final int value;
  final void Function(int) onChange;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    Widget bouton(IconData i, VoidCallback? f) => IconButton(
      onPressed: f,
      style: IconButton.styleFrom(
        backgroundColor: p.surfaceMuted,
        fixedSize: const Size(42, 42),
      ),
      icon: Icon(i, size: 18),
    );
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: p.border, width: 1.5),
        borderRadius: BorderRadius.circular(16),
        color: p.paper,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          bouton(
            PhosphorIconsLight.minus,
            value > 1 ? () => onChange(value - 1) : null,
          ),
          SizedBox(
            width: 36,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: p.text,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          bouton(PhosphorIconsLight.plus, () => onChange(value + 1)),
        ],
      ),
    );
  }
}
