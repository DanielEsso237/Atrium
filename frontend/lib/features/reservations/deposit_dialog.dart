/// Les arrhes, au moment d'enregistrer une reservation.
///
/// La regle de l'hotel (Administration -> Arrhes) dit combien demander. Le
/// client paie tout de suite -- especes au comptoir, Orange Money, MTN MoMo,
/// virement, carte -- ou plus tard : la reservation est alors enregistree
/// avec des arrhes dues, rien d'encaisse.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/formats.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/enums.dart';
import '../billing/charge_labels.dart';
import '../billing/payment_dialog.dart' show iconePaiement;

/// Ce que la reception decide. `montant` nul : arrhes dues, payees plus tard.
class DepositChoice {
  const DepositChoice.plusTard() : montant = null, moyen = null;
  const DepositChoice.encaisser(int this.montant, PaymentMethod this.moyen);

  final int? montant;
  final PaymentMethod? moyen;
}

/// Rend le choix, ou `null` si la reception renonce a enregistrer.
Future<DepositChoice?> askDeposit(
  BuildContext context, {
  required int du,
  required int total,
  required String regle,
}) {
  return showDialog<DepositChoice>(
    context: context,
    builder: (_) => _DepositDialog(du: du, total: total, regle: regle),
  );
}

class _DepositDialog extends StatefulWidget {
  const _DepositDialog({
    required this.du,
    required this.total,
    required this.regle,
  });

  final int du;
  final int total;
  final String regle;

  @override
  State<_DepositDialog> createState() => _DepositDialogState();
}

class _DepositDialogState extends State<_DepositDialog> {
  late final _montant = TextEditingController(text: '${widget.du}');
  PaymentMethod _moyen = PaymentMethod.CASH;

  /// Les moyens des arrhes (reunion du 29 septembre) : especes au comptoir,
  /// sinon Mobile Money, virement ou carte.
  static const _moyens = [
    PaymentMethod.CASH,
    PaymentMethod.MOBILE_MONEY,
    PaymentMethod.TRANSFER,
    PaymentMethod.CARD,
  ];

  @override
  void dispose() {
    _montant.dispose();
    super.dispose();
  }

  int get _saisi => int.tryParse(_montant.text.trim()) ?? 0;

  /// Les deux refus du serveur, dits ici plutot que de bloquer la file.
  String? get _erreur {
    if (_saisi <= 0) return 'Un montant supérieur à zéro';
    if (_saisi > widget.total) {
      return 'Pas plus que le séjour (${formatAmount(widget.total)})';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      icon: const Icon(PhosphorIconsLight.coins, size: 30),
      title: Text('Arrhes : ${formatAmount(widget.du)}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.regle} d’un séjour à ${formatAmount(widget.total)}. '
              'Elles seront déduites de l’ardoise à l’arrivée, et restent '
              'acquises si la réservation est annulée.',
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            ChoiceTiles<PaymentMethod>(
              selected: _moyen,
              tileWidth: 148,
              onChanged: (m) => setState(() => _moyen = m),
              options: [
                for (final m in _moyens)
                  (m, iconePaiement(m), paymentMethodLabel(m)),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _montant,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Montant reçu',
                suffixText: 'FCFA',
                errorText: _erreur,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(const DepositChoice.plusTard()),
          child: const Text('Payées plus tard'),
        ),
        FilledButton(
          onPressed: _erreur != null
              ? null
              : () => Navigator.of(
                  context,
                ).pop(DepositChoice.encaisser(_saisi, _moyen)),
          child: const Text('Encaisser'),
        ),
      ],
    );
  }
}
