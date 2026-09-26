/// Prise de poste et fin de service : la caisse (F1.4).
///
/// Deux gestes, une fois chacun par service. D'ou un seul bouton qui change de
/// sens selon l'etat : ouvrir quand il n'y a pas de caisse, fermer quand il y
/// en a une.
///
/// **L'attendu ne s'affiche pas avant le comptage.** Montrer « vous devriez
/// avoir 48 000 » puis demander de compter, c'est demander de confirmer un
/// chiffre plutot que de compter. L'agent saisit ce qu'il a dans le tiroir, et
/// l'ecart se revele ensuite.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../data/repositories/cash_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

/// Le bouton de caisse du module Factures.
class CashButton extends ConsumerWidget {
  const CashButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(sessionProvider).agent?.id;
    if (agent == null) return const SizedBox.shrink();

    final caisse = ref.watch(currentCashProvider(agent));

    return caisse.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (vue) => vue == null
          ? OutlinedButton.icon(
              onPressed: () => _ouvrir(context, ref, agent),
              icon: const Icon(Icons.lock_open_outlined),
              label: const Text('Ouvrir la caisse'),
            )
          : FilledButton.icon(
              onPressed: () => _fermer(context, ref, vue),
              icon: const Icon(Icons.point_of_sale_outlined),
              label: Text('Caisse · ${formatAmountShort(vue.expected)}'),
            ),
    );
  }

  Future<void> _ouvrir(
    BuildContext context,
    WidgetRef ref,
    String agent,
  ) async {
    final montant = await _demanderMontant(
      context,
      titre: 'Ouvrir la caisse',
      question: 'Combien y a-t-il dans le tiroir en prenant votre poste ?',
      champ: 'Fond de caisse (FCFA)',
      action: 'Ouvrir',
    );
    if (montant == null || !context.mounted) return;

    try {
      await ref
          .read(cashRepositoryProvider)
          .open(userId: agent, openingFloat: montant);
    } on StateError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Caisse ouverte a ${formatAmount(montant)}.')),
    );
  }

  Future<void> _fermer(
    BuildContext context,
    WidgetRef ref,
    CashView vue,
  ) async {
    final compte = await _demanderMontant(
      context,
      titre: 'Fermer la caisse',
      question:
          'Comptez le tiroir et saisissez ce que vous trouvez. '
          'L\'ecart s\'affichera ensuite.',
      champ: 'Montant compte (FCFA)',
      action: 'Fermer',
    );
    if (compte == null || !context.mounted) return;

    final int ecart;
    try {
      ecart = await ref
          .read(cashRepositoryProvider)
          .close(sessionId: vue.session.id, countedAmount: compte);
    } on StateError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _Resultat(attendu: vue.expected, compte: compte, ecart: ecart),
    );
  }
}

/// Le bilan de fermeture. Un ecart se regarde en face.
class _Resultat extends StatelessWidget {
  const _Resultat({
    required this.attendu,
    required this.compte,
    required this.ecart,
  });

  final int attendu;
  final int compte;
  final int ecart;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final juste = ecart == 0;

    return AlertDialog(
      title: const Text('Caisse fermee'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Ligne(label: 'Attendu', montant: attendu),
            _Ligne(label: 'Compte', montant: compte),
            const Divider(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: juste ? schema.primaryContainer : schema.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    juste ? 'Caisse juste' : 'Ecart',
                    style: TextStyle(
                      fontSize: 15,
                      color: juste
                          ? schema.onPrimaryContainer
                          : schema.onErrorContainer,
                    ),
                  ),
                  if (!juste) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${ecart > 0 ? '+' : ''}${formatAmount(ecart)}',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: schema.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      ecart > 0 ? 'de trop dans le tiroir' : 'manquants',
                      style: TextStyle(
                        fontSize: 14,
                        color: schema.onErrorContainer,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Termine'),
        ),
      ],
    );
  }
}

class _Ligne extends StatelessWidget {
  const _Ligne({required this.label, required this.montant});

  final String label;
  final int montant;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 16)),
        const Spacer(),
        Text(
          formatAmount(montant),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

Future<int?> _demanderMontant(
  BuildContext context, {
  required String titre,
  required String question,
  required String champ,
  required String action,
}) {
  final controleur = TextEditingController();

  return showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(titre),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(question, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 16),
            TextField(
              controller: controleur,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: champ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () {
            final n = int.tryParse(controleur.text.trim());
            if (n == null || n < 0) return;
            Navigator.of(dialogContext).pop(n);
          },
          child: Text(action),
        ),
      ],
    ),
  );
}
