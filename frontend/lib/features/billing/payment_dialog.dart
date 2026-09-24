/// Encaisser sur une ardoise (F1.4).
///
/// Vit dans son propre fichier parce qu'on encaisse depuis deux endroits : le
/// module Factures, ou on solde une ardoise a tete reposee, et la confirmation
/// de depart, ou le client est devant le comptoir et attend sa note. Le second
/// est le cas courant ; l'enfermer dans l'ecran des factures obligeait a
/// traverser trois ecrans au pire moment.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import 'charge_labels.dart';

/// Propose d'encaisser sur `folioId`.
///
/// Renvoie le montant reellement encaisse, ou `0` si l'agent a renonce.
/// L'appelant en a besoin : apres un encaissement partiel, il reste quelque
/// chose a demander.
Future<int> showPaymentDialog(
  BuildContext context, {
  required String folioId,
  required String guestName,
  required int balance,
}) async {
  final encaisse = await showDialog<int>(
    context: context,
    builder: (_) => _PaymentDialog(
      folioId: folioId,
      guestName: guestName,
      balance: balance,
    ),
  );
  return encaisse ?? 0;
}

class _PaymentDialog extends ConsumerStatefulWidget {
  const _PaymentDialog({
    required this.folioId,
    required this.guestName,
    required this.balance,
  });

  final String folioId;
  final String guestName;
  final int balance;

  @override
  ConsumerState<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<_PaymentDialog> {
  late final TextEditingController _amount;
  final _reference = TextEditingController();
  PaymentMethod _method = PaymentMethod.CASH;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Pre-rempli au solde : le cas courant est qu'on encaisse tout.
    _amount = TextEditingController(text: '${widget.balance}');
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final montant = int.tryParse(_amount.text.trim()) ?? 0;
    if (montant <= 0) return;
    setState(() => _busy = true);

    // Toute erreur se dit et rend le bouton : un dialogue fige sur un bouton
    // grise se lit comme une panne, et l'agent annule sans savoir si
    // l'argent a ete enregistre ou non.
    try {
      await ref
          .read(folioRepositoryProvider)
          .addPayment(
            folioId: widget.folioId,
            method: _method,
            amount: montant,
            reference: _reference.text.trim().isEmpty
                ? null
                : _reference.text.trim(),
            receivedBy: ref.read(sessionProvider).agent?.id,
          );
    } on StateError catch (e) {
      // Refus attendu -- ardoise close, deja soldee, montant superieur au
      // reste du. Le message du depot est ecrit pour etre lu par un agent :
      // on le montre tel quel plutot que « Bad state: ... ».
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Echec : $e')));
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(montant);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${formatAmount(montant)} encaisse.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Encaisser — ${widget.guestName}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<PaymentMethod>(
              initialValue: _method,
              decoration: const InputDecoration(labelText: 'Moyen'),
              items: [
                for (final m in PaymentMethod.values)
                  DropdownMenuItem(
                    value: m,
                    child: Text(paymentMethodLabel(m)),
                  ),
              ],
              onChanged: (v) =>
                  setState(() => _method = v ?? PaymentMethod.CASH),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Montant (FCFA)',
                helperText: 'Reste du : ${formatAmount(widget.balance)}',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reference,
              decoration: const InputDecoration(
                labelText: 'Reference',
                helperText: 'Numero de transaction, facultatif',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(0),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Encaisser'),
        ),
      ],
    );
  }
}
