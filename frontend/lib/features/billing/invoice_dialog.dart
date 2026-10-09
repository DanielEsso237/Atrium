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
import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/repositories/invoice_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../hotel/en_tete_hotel.dart';
import '../hotel/logo_images.dart';
import 'invoice_pdf.dart';

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

  /// Fabrique le PDF demande et le remet a l'agent.
  Future<void> _exporter(
    BuildContext context,
    WidgetRef ref,
    InvoiceView vue, {
    required bool ticket,
  }) async {
    final messager = ScaffoldMessenger.of(context);
    final boite = context.findRenderObject() as RenderBox?;
    final origine = boite == null
        ? null
        : boite.localToGlobal(Offset.zero) & boite.size;
    try {
      final hotel = await ref.read(hotelProvider.future);
      final octets = ticket
          ? await factureTicket(
              vue: vue,
              hotel: hotel,
              client: guestName,
              logoNoirBlanc: await ref.read(logoTicketProvider.future),
            )
          : await factureA4(vue: vue, hotel: hotel, client: guestName);
      final numero = vue.displayNumber.replaceAll(RegExp('[^A-Za-z0-9-]'), '');
      await partagerPdf(
        octets,
        nom: ticket ? 'ticket-$numero' : 'facture-$numero',
        sujet: 'Facture ${vue.displayNumber}',
        origine: origine,
      );
    } catch (e) {
      messager.showSnackBar(
        SnackBar(content: Text("Le PDF n'a pas pu être préparé : $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facture = ref.watch(invoiceForFolioProvider(folioId));
    final hotel = ref.watch(hotelProvider).value;
    final vue = facture.value;
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
            return _Corps(vue: vue, guestName: guestName, hotel: hotel);
          },
        ),
      ),
      actions: [
        if (vue != null) ...[
          // Le ticket pour l'imprimante de caisse, en noir et blanc ; la page
          // A4 pour l'envoyer ou l'imprimer au bureau.
          TextButton.icon(
            onPressed: () => _exporter(context, ref, vue, ticket: true),
            icon: const Icon(PhosphorIconsLight.receipt, size: 18),
            label: const Text('Ticket'),
          ),
          TextButton.icon(
            onPressed: () => _exporter(context, ref, vue, ticket: false),
            icon: const Icon(PhosphorIconsLight.filePdf, size: 18),
            label: const Text('PDF'),
          ),
        ],
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
  const _Corps({required this.vue, required this.guestName, this.hotel});

  final InvoiceView vue;
  final String guestName;
  final HotelRow? hotel;

  static const _encre = Color(0xFF1C2333);
  static const _gris = Color(0xFF5E6880);

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
                color: const Color(0xFFD5DBE7),
              ),
          ],
        ),
      ),
    );

    return SingleChildScrollView(
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 26),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x2414244F),
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
            // Le logo et les coordonnees de l'hotel, reglés dans
            // l'administration ; son nom seul tant qu'il n'a pas de logo.
            EnTeteFacture(
              hotel: hotel,
              titre: 'Facture',
              numero: vue.displayNumber,
            ),
            const SizedBox(height: 20),
            Text('Client', style: st(12, FontWeight.w600, _gris)),
            Text(guestName, style: st(17, FontWeight.w700)),
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
                  style: st(30, FontWeight.w700).copyWith(letterSpacing: -1),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
