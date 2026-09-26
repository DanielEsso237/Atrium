/// La facture d'une ardoise (F1.4).
///
/// Ce que le client emporte. D'ou une mise en page qui tient sur une feuille
/// et se lit sans explication : un numero, des lignes, un total.
///
/// **Le numero provisoire se signale.** Une facture editee hors ligne porte un
/// numero que la tablette s'est donne a elle-meme ; il n'a aucune valeur
/// comptable tant que le serveur n'a pas attribue le numero legal. Le taire
/// ferait remettre au client un document qui a l'air definitif et ne l'est
/// pas.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../data/repositories/invoice_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

/// Edite la facture si besoin, puis la montre.
Future<void> showInvoiceDialog(
  BuildContext context,
  WidgetRef ref, {
  required String folioId,
  required String guestName,
}) async {
  try {
    await ref
        .read(invoiceRepositoryProvider)
        .issue(folioId, by: ref.read(sessionProvider).agent?.id);
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
    builder: (_) => _InvoiceDialog(folioId: folioId, guestName: guestName),
  );
}

class _InvoiceDialog extends ConsumerWidget {
  const _InvoiceDialog({required this.folioId, required this.guestName});

  final String folioId;
  final String guestName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facture = ref.watch(invoiceForFolioProvider(folioId));
    final schema = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Facture'),
      content: SizedBox(
        width: 520,
        child: facture.when(
          loading: () => const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('Erreur : $e'),
          data: (vue) {
            if (vue == null) return const Text('Aucune facture.');
            return _Corps(vue: vue, guestName: guestName, schema: schema);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}

class _Corps extends StatelessWidget {
  const _Corps({
    required this.vue,
    required this.guestName,
    required this.schema,
  });

  final InvoiceView vue;
  final String guestName;
  final ColorScheme schema;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            vue.displayNumber,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(guestName, style: TextStyle(fontSize: 16, color: schema.outline)),

          if (vue.provisional) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: schema.tertiaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Numero provisoire. Le numero definitif sera attribue par le '
                'serveur des que cette facture y sera remontee.',
                style: TextStyle(
                  fontSize: 14,
                  color: schema.onTertiaryContainer,
                ),
              ),
            ),
          ],

          const SizedBox(height: 18),
          const Divider(height: 1),
          for (final l in vue.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l.quantity > 1 ? '${l.label} × ${l.quantity}' : l.label,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                  Text(
                    formatAmount(l.amount),
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),

          const SizedBox(height: 14),
          Row(
            children: [
              const Text(
                'Total',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                formatAmount(vue.invoice.total),
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
