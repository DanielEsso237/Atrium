/// Le depart : jusqu'a quelle heure, et combien l'heure de plus.
///
/// Une nuitee va de 12 h a 12 h par defaut. Au-dela, la reception propose de
/// facturer la prolongation heure par heure ; un prix a zero desactive la
/// proposition.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/prolongation.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/settings_repository.dart';

class StayRulesSection extends ConsumerStatefulWidget {
  const StayRulesSection({super.key});

  @override
  ConsumerState<StayRulesSection> createState() => _StayRulesSectionState();
}

class _StayRulesSectionState extends ConsumerState<StayRulesSection> {
  final _heure = TextEditingController();
  final _prix = TextEditingController();
  bool _initialise = false;
  bool _busy = false;

  @override
  void dispose() {
    _heure.dispose();
    _prix.dispose();
    super.dispose();
  }

  void _depuis(StayRules regles) {
    _initialise = true;
    _heure.text = '${regles.checkoutHour}';
    _prix.text = regles.extraHourPrice == 0 ? '' : '${regles.extraHourPrice}';
  }

  int? get _heureSaisie {
    final h = int.tryParse(_heure.text.trim());
    return h != null && h >= 0 && h <= 23 ? h : null;
  }

  /// Un prix vide vaut zero : pas de facturation de la prolongation.
  int? get _prixSaisi {
    final texte = _prix.text.trim();
    return texte.isEmpty ? 0 : int.tryParse(texte);
  }

  bool get _saisieValide => _heureSaisie != null && _prixSaisi != null;

  Future<void> _enregistrer() async {
    setState(() => _busy = true);
    await ref
        .read(settingsRepositoryProvider)
        .setStayRules(
          StayRules(checkoutHour: _heureSaisie!, extraHourPrice: _prixSaisi!),
        );
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Heure de départ enregistrée.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final regles = ref.watch(stayRulesProvider);
    final p = AtriumPalette.current;

    if (!_initialise && regles.hasValue) _depuis(regles.value!);

    final heure = _heureSaisie;
    final prix = _prixSaisi;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Eyebrow('Heure de départ et prolongation'),
        const SizedBox(height: 14),
        SizedBox(
          width: 260,
          child: TextField(
            controller: _heure,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Heure de départ',
              suffixText: 'h',
              errorText: heure != null || _heure.text.isEmpty
                  ? null
                  : 'De 0 à 23',
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: 260,
          child: TextField(
            controller: _prix,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Prix de l’heure supplémentaire',
              suffixText: 'FCFA',
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          heure == null || prix == null
              ? 'Saisissez une heure entre 0 et 23.'
              : prix == 0
              ? 'Départ à $heure h. La prolongation n’est pas facturée.'
              : 'Départ à $heure h. Chaque heure entamée au-delà coûte '
                    '${formatAmount(prix)} : un client qui part à '
                    '${(heure + 2) % 24} h paie 2 h, soit '
                    '${formatAmount(2 * prix)}.',
          style: TextStyle(fontSize: 16, color: p.textSecondary),
        ),
        const SizedBox(height: 6),
        Text(
          'Une nuitée va de $heureDepartParDefaut h à $heureDepartParDefaut h '
          'par défaut ; elle est distincte de la journée d’exploitation, qui '
          'bascule à 6 h.',
          style: TextStyle(fontSize: 13.5, color: p.textSecondary),
        ),
        const SizedBox(height: 22),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: 'Enregistrer',
            tone: PillTone.accent,
            onPressed: _busy || !_saisieValide ? null : _enregistrer,
          ),
        ),
      ],
    );
  }
}
