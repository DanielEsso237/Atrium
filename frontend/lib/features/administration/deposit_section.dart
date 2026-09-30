/// La regle des arrhes : aucune, une somme fixe, ou un pourcentage du sejour.
///
/// Un exemple calcule accompagne la saisie : « 30 % » ne dit rien a qui
/// pense en francs, « soit 7 500 FCFA sur une chambre a 25 000 FCFA » si.
library;

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../data/local/database_provider.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/settings_repository.dart';

final _regleArrhes = StreamProvider<DepositRule?>(
  (ref) => ref.watch(settingsRepositoryProvider).watchDepositRule(),
);

/// Le prix d'une nuit dans la premiere categorie : la base de l'exemple.
final _prixDeReference = FutureProvider<int>((ref) async {
  final db = ref.watch(databaseProvider);
  final types = await (db.select(db.roomTypes)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
      .get();
  final avecPrix = types.where((t) => t.defaultRate > 0);
  return avecPrix.isEmpty ? 25000 : avecPrix.first.defaultRate;
});

/// 3000 points de base -> « 30 % » ; 1250 -> « 12,5 % ».
String formatRate(int rateBp) {
  final entier = rateBp ~/ 100;
  final reste = rateBp % 100;
  if (reste == 0) return '$entier %';
  final decimales = reste % 10 == 0 ? '${reste ~/ 10}' : '$reste'.padLeft(2, '0');
  return '$entier,$decimales %';
}

/// « 30 » ou « 12,5 » -> points de base, sans passer par un decimal.
///
/// `null` si la saisie n'est pas un pourcentage de 0,01 a 100.
int? parseRateBp(String saisie) {
  final m = RegExp(r'^(\d{1,3})(?:[.,](\d{1,2}))?$').firstMatch(saisie.trim());
  if (m == null) return null;
  final decimales = (m.group(2) ?? '').padRight(2, '0');
  final bp = int.parse(m.group(1)!) * 100 + int.parse(decimales);
  return bp > 0 && bp <= 10000 ? bp : null;
}

/// L'exemple affiche sous la regle.
String describeRule(DepositRule? regle, int prixNuit) {
  if (regle == null) return 'Aucune arrhe n’est demandée par défaut.';
  final du = regle.depositFor(prixNuit);
  final quoi = regle.isFixed ? formatAmount(regle.amount!) : formatRate(regle.rateBp!);
  return '$quoi — soit ${formatAmount(du)} sur une chambre à '
      '${formatAmount(prixNuit)} la nuit.';
}

enum _Mode { aucune, fixe, pourcentage }

class DepositSection extends ConsumerStatefulWidget {
  const DepositSection({super.key});

  @override
  ConsumerState<DepositSection> createState() => _DepositSectionState();
}

class _DepositSectionState extends ConsumerState<DepositSection> {
  final _valeur = TextEditingController();
  _Mode _mode = _Mode.aucune;
  bool _initialise = false;
  bool _busy = false;

  @override
  void dispose() {
    _valeur.dispose();
    super.dispose();
  }

  void _depuis(DepositRule? regle) {
    _initialise = true;
    if (regle == null) {
      _mode = _Mode.aucune;
      _valeur.text = '';
    } else if (regle.isFixed) {
      _mode = _Mode.fixe;
      _valeur.text = '${regle.amount}';
    } else {
      _mode = _Mode.pourcentage;
      _valeur.text = formatRate(regle.rateBp!).replaceAll(' %', '');
    }
  }

  /// La regle telle que saisie ; `null` en mode aucune ou si la saisie est
  /// invalide (voir `_saisieValide`).
  DepositRule? get _regleSaisie {
    switch (_mode) {
      case _Mode.aucune:
        return null;
      case _Mode.fixe:
        final montant = int.tryParse(_valeur.text.trim());
        return montant == null || montant <= 0 ? null : DepositRule.fixed(montant);
      case _Mode.pourcentage:
        final bp = parseRateBp(_valeur.text);
        return bp == null ? null : DepositRule.percent(bp);
    }
  }

  bool get _saisieValide => _mode == _Mode.aucune || _regleSaisie != null;

  Future<void> _enregistrer() async {
    setState(() => _busy = true);
    await ref.read(settingsRepositoryProvider).setDepositRule(_regleSaisie);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Règle des arrhes enregistrée.')));
  }

  @override
  Widget build(BuildContext context) {
    final regle = ref.watch(_regleArrhes);
    final prix = ref.watch(_prixDeReference).value ?? 25000;
    final p = AtriumPalette.current;

    if (!_initialise && regle.hasValue) _depuis(regle.value);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Eyebrow('Arrhes demandées à la réservation'),
        const SizedBox(height: 14),
        SegmentedButton<_Mode>(
          segments: const [
            ButtonSegment(value: _Mode.aucune, label: Text('Aucune')),
            ButtonSegment(value: _Mode.fixe, label: Text('Somme fixe')),
            ButtonSegment(value: _Mode.pourcentage, label: Text('Pourcentage')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: 16),
        if (_mode != _Mode.aucune)
          SizedBox(
            width: 260,
            child: TextField(
              controller: _valeur,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                if (_mode == _Mode.fixe) FilteringTextInputFormatter.digitsOnly,
              ],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _mode == _Mode.fixe ? 'Montant' : 'Pourcentage du séjour',
                suffixText: _mode == _Mode.fixe ? 'FCFA' : '%',
                errorText: _saisieValide || _valeur.text.isEmpty
                    ? null
                    : _mode == _Mode.fixe
                    ? 'Un montant supérieur à zéro'
                    : 'De 0,01 à 100',
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          describeRule(_saisieValide ? _regleSaisie : null, prix),
          style: TextStyle(fontSize: 16, color: p.textSecondary),
        ),
        const SizedBox(height: 6),
        Text(
          'Les arrhes ne dépassent jamais le prix du séjour. Elles restent '
          'acquises si la réservation est annulée.',
          style: TextStyle(fontSize: 13.5, color: p.textSecondary),
        ),
        const SizedBox(height: 22),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: 'Enregistrer la règle',
            tone: PillTone.accent,
            onPressed: _busy || !_saisieValide ? null : _enregistrer,
          ),
        ),
      ],
    );
  }
}
