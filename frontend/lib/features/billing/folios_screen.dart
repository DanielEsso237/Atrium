/// Les ardoises (cahier des charges, F1.4).
///
/// Le folio est le centre de la facturation : toute consommation y atterrit,
/// et la facture n'est qu'un gel du folio a un instant donne. C'est la
/// decision structurante n°3 du projet.
///
/// Les ouvertes en premier, parce que ce sont les seules sur lesquelles la
/// reception a quelque chose a faire.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database.dart';
import '../../data/repositories/folio_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import 'charge_labels.dart';
import 'invoice_dialog.dart';
import 'payment_dialog.dart';

final foliosProvider = StreamProvider<List<FolioSummary>>(
  (ref) => ref.watch(folioRepositoryProvider).watchFolios(),
);

final folioItemsProvider = StreamProvider.family<List<FolioItemRow>, String>(
  (ref, folioId) => ref.watch(folioRepositoryProvider).watchItems(folioId),
);

final folioPaymentsProvider = StreamProvider.family<List<PaymentRow>, String>(
  (ref, folioId) => ref.watch(folioRepositoryProvider).watchPayments(folioId),
);

class FoliosScreen extends ConsumerWidget {
  const FoliosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folios = ref.watch(foliosProvider);
    final schema = Theme.of(context).colorScheme;

    return ModuleScaffold(
      title: 'Factures',
      body: folios.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Lecture impossible : $e')),
        data: (list) => list.isEmpty
            ? Center(
                child: Text(
                  'Aucune ardoise. Elles s\'ouvrent a l\'arrivee d\'un client.',
                  style: TextStyle(fontSize: 18, color: schema.outline),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(24),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _FolioCard(folio: list[i]),
              ),
      ),
    );
  }
}

class _FolioCard extends StatelessWidget {
  const _FolioCard({required this.folio});

  final FolioSummary folio;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    // Un solde du se voit de loin ; une ardoise soldee n'a pas besoin
    // d'attirer l'oeil.
    final couleur = folio.balance > 0
        ? schema.error
        : (folio.isOpen ? const Color(0xFF2E7D32) : schema.outline);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => FractionallySizedBox(
            heightFactor: 0.9,
            child: _FolioSheet(folio: folio),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 56,
                decoration: BoxDecoration(
                  color: couleur,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          folio.guestName,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (folio.roomNumber != null) ...[
                          const SizedBox(width: 10),
                          Chip(
                            label: Text('Ch. ${folio.roomNumber}'),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                        if (!folio.isOpen) ...[
                          const SizedBox(width: 10),
                          Chip(
                            label: const Text('Close'),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: schema.surfaceContainerHighest,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${folio.number} · ${formatAmount(folio.chargesTotal)} '
                      'porte · ${formatAmount(folio.paymentsTotal)} encaisse',
                      style: TextStyle(fontSize: 15, color: schema.outline),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    folio.balance > 0 ? 'Reste du' : 'Solde',
                    style: TextStyle(fontSize: 14, color: schema.outline),
                  ),
                  Text(
                    formatAmount(folio.balance),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: couleur,
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

class _FolioSheet extends ConsumerWidget {
  const _FolioSheet({required this.folio});

  final FolioSummary folio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(folioItemsProvider(folio.id));
    final payments = ref.watch(folioPaymentsProvider(folio.id));
    // La carte d'origine peut etre perimee : on relit la liste pour avoir le
    // solde a jour apres un encaissement.
    final live = ref
        .watch(foliosProvider)
        .value
        ?.where((f) => f.id == folio.id)
        .firstOrNull;
    final current = live ?? folio;
    final schema = Theme.of(context).colorScheme;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF4F6F8),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current.guestName,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        current.number,
                        style: TextStyle(fontSize: 16, color: schema.outline),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  iconSize: 30,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _Totals(folio: current),
                const SizedBox(height: 16),
                _Block(
                  title: 'Consommations',
                  child: items.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('$e'),
                    data: (lignes) => lignes.isEmpty
                        ? Text(
                            'Rien de porte a cette ardoise.',
                            style: TextStyle(
                              fontSize: 17,
                              color: schema.outline,
                            ),
                          )
                        : Column(
                            children: [
                              for (final l in lignes)
                                _Line(
                                  label: l.label,
                                  detail:
                                      '${chargeCategoryLabel(l.category)} · ${l.businessDate}'
                                      '${l.quantity > 1 ? ' · x${l.quantity}' : ''}',
                                  amount: l.amount,
                                ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                _Block(
                  title: 'Encaissements',
                  child: payments.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('$e'),
                    data: (lignes) => lignes.isEmpty
                        ? Text(
                            'Aucun encaissement.',
                            style: TextStyle(
                              fontSize: 17,
                              color: schema.outline,
                            ),
                          )
                        : Column(
                            children: [
                              for (final p in lignes)
                                _Line(
                                  label: paymentMethodLabel(p.method),
                                  detail: p.reference ?? '',
                                  amount: -p.amount,
                                ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
          _Actions(folio: current),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.folio});

  final FolioSummary folio;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _Line(label: 'Total porte', amount: folio.chargesTotal),
            _Line(label: 'Total encaisse', amount: -folio.paymentsTotal),
            const Divider(height: 24),
            Row(
              children: [
                Text(
                  folio.balance > 0 ? 'Reste du' : 'Solde',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  formatAmount(folio.balance),
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: folio.balance > 0 ? schema.error : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.folio});

  final FolioSummary folio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!folio.isOpen) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        color: Colors.white,
        child: Text(
          'Ardoise close. Plus rien ne peut y etre porte.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE0E0E0))),
      ),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: folio.balance <= 0
                  ? null
                  : () => _encaisser(context, ref),
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Encaisser'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              // Editer avant d'encaisser est legitime : le client veut voir
              // ce qu'il doit avant de payer. La seule condition est qu'il y
              // ait quelque chose a facturer.
              onPressed: () => showInvoiceDialog(
                context,
                ref,
                folioId: folio.id,
                guestName: folio.guestName,
              ),
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('Facture'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              // Une ardoise close avec un impaye est une creance que plus
              // personne ne verra : la cloture attend un solde nul.
              onPressed: folio.balance != 0 ? null : () => _clore(context, ref),
              icon: const Icon(Icons.lock_outline),
              label: const Text('Clore'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _encaisser(BuildContext context, WidgetRef ref) async {
    await showPaymentDialog(
      context,
      folioId: folio.id,
      guestName: folio.guestName,
      balance: folio.balance,
    );
  }

  Future<void> _clore(BuildContext context, WidgetRef ref) async {
    try {
      await ref
          .read(folioRepositoryProvider)
          .close(folio.id, by: ref.read(sessionProvider).agent?.id);
      if (!context.mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ardoise ${folio.number} close.')));
    } on StateError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.amount, this.detail});

  final String label;
  final String? detail;
  final int amount;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 17)),
                if (detail != null && detail!.isNotEmpty)
                  Text(
                    detail!,
                    style: TextStyle(fontSize: 14, color: schema.outline),
                  ),
              ],
            ),
          ),
          Text(
            formatAmount(amount),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
