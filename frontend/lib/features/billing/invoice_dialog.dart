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

import '../../core/brand/atrium_logo.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
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
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
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
            return _Corps(vue: vue, guestName: guestName);
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

/// La facture elle-meme : une feuille de papier, meme en mode nuit. C'est un
/// document que le client emporte, pas un ecran.
class _Corps extends StatelessWidget {
  const _Corps({required this.vue, required this.guestName});

  final InvoiceView vue;
  final String guestName;

  static const _encre = Color(0xFF0D1330);
  static const _gris = Color(0xFF5B6386);

  @override
  Widget build(BuildContext context) {
    TextStyle st(double taille, FontWeight poids, [Color c = _encre]) =>
        TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: taille,
          fontWeight: poids,
          color: c,
          fontFeatures: tabularFigures,
        );
    Widget pointilles() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: LayoutBuilder(
        builder: (_, c) => Row(
          children: [
            for (var i = 0; i < c.maxWidth ~/ 8; i++)
              Container(
                width: 4,
                height: 1.4,
                margin: const EdgeInsets.only(right: 4),
                color: const Color(0xFFCBD0E2),
              ),
          ],
        ),
      ),
    );

    return SingleChildScrollView(
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 26),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFDF8),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 30,
              spreadRadius: -12,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AtriumLockup(
                  markSize: 38,
                  onNight: false,
                  ink: _encre,
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('FACTURE', style: st(11, FontWeight.w800, _gris)),
                    Text(vue.displayNumber, style: st(16, FontWeight.w800)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Client', style: st(12, FontWeight.w600, _gris)),
            Text(guestName, style: st(17, FontWeight.w800)),
            if (vue.provisional) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF1D6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      PhosphorIconsLight.clockCountdown,
                      size: 18,
                      color: Color(0xFF9A5A00),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Numéro provisoire. Le numéro définitif sera attribué '
                        'par le serveur dès que cette facture y sera remontée.',
                        style: st(13, FontWeight.w500, const Color(0xFF6B4200)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            pointilles(),
            for (final l in vue.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l.quantity > 1 ? '${l.label} × ${l.quantity}' : l.label,
                        style: st(14.5, FontWeight.w500),
                      ),
                    ),
                    Text(
                      formatAmount(l.amount),
                      style: st(14.5, FontWeight.w700),
                    ),
                  ],
                ),
              ),
            pointilles(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Total', style: st(16, FontWeight.w700, _gris)),
                const Spacer(),
                Text(
                  formatAmount(vue.invoice.total),
                  style: st(30, FontWeight.w800).copyWith(letterSpacing: -1),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
