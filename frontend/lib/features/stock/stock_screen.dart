/// Les stocks : l'economat et le stock de chaque point de vente.
///
/// L'economat ravitaille les points de vente, qui se ravitaillent aussi entre
/// eux (le bar qui manque de jus en prend a la boite de nuit). Un transfert
/// attend la validation du controleur ou du comptable, un seul suffit ; le
/// stock ne bouge qu'a ce moment-la.
///
/// Un stock peut etre negatif : il est theorique, et une vente ne se refuse
/// pas pour autant (decision du 8 octobre). L'ecran le montre en rouge, pour
/// que l'econome corrige.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/stock_repository.dart';
import '../auth/session.dart';

class _MagasinChoisi extends Notifier<String?> {
  @override
  String? build() => null;

  void choisir(String id) => state = id;
}

final _magasinChoisiProvider = NotifierProvider<_MagasinChoisi, String?>(
  _MagasinChoisi.new,
);

class StockScreen extends ConsumerWidget {
  const StockScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final magasins = ref.watch(stockPlacesProvider(session.agent?.id));
    final acces = session.acces;
    final peutBouger = acces.peut('stock.movement');
    final peutValider = acces.peut('stock.transfer.approve');

    return magasins.when(
      loading: () => const ModuleScaffold(
        title: 'Stocks',
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ModuleScaffold(
        title: 'Stocks',
        body: EmptyState(
          icon: PhosphorIconsLight.warningCircle,
          title: 'Lecture impossible',
          message: '$e',
        ),
      ),
      data: (liste) {
        if (liste.isEmpty) {
          return const ModuleScaffold(
            title: 'Stocks',
            body: EmptyState(
              icon: PhosphorIconsLight.archive,
              title: 'Aucun magasin',
              message:
                  'L’économat et les stocks des points de vente arrivent du '
                  'serveur : lancez une synchronisation.',
            ),
          );
        }
        final choisiId = ref.watch(_magasinChoisiProvider);
        final magasin = liste.firstWhere(
          (m) => m.id == choisiId,
          orElse: () => liste.first,
        );
        final etroit = MediaQuery.sizeOf(context).width < 600;
        final marge = etroit ? 18.0 : 32.0;

        return ModuleScaffold(
          title: 'Stocks',
          subtitle: magasin.isCentral
              ? 'L’économat ravitaille les points de vente'
              : 'Stock du point de vente ${magasin.label}',
          action: peutBouger
              ? Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    if (magasin.isCentral)
                      PillButton(
                        label: 'Entrée',
                        icon: PhosphorIconsLight.plus,
                        tone: PillTone.accent,
                        onPressed: () => _entree(context, ref, magasin),
                      ),
                    PillButton(
                      label: 'Transfert',
                      icon: PhosphorIconsLight.arrowsLeftRight,
                      tone: PillTone.quiet,
                      onPressed: () => _transfert(context, ref, magasin, liste),
                    ),
                  ],
                )
              : null,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
                child: FilterPills<String>(
                  selected: magasin.id,
                  onChanged: (id) =>
                      ref.read(_magasinChoisiProvider.notifier).choisir(id),
                  options: [
                    for (final m in liste) FilterOption(m.id, m.label),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
                  children: [
                    if (peutValider) const _AValider(),
                    _Lignes(magasin: magasin),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _entree(
    BuildContext context,
    WidgetRef ref,
    StockPlace magasin,
  ) async {
    final saisie = await showDialog<_Saisie>(
      context: context,
      builder: (_) => _SaisieDialog(titre: 'Entrée à ${magasin.label}', entree: true),
    );
    if (saisie == null || !context.mounted) return;
    await _faire(context, () async {
      await ref
          .read(stockRepositoryProvider)
          .receive(
            placeId: magasin.id,
            productId: saisie.produit.id,
            quantity: saisie.quantite,
            unitCost: saisie.prixAchat,
            reason: saisie.motif,
            by: ref.read(sessionProvider).agent?.id,
          );
      return '${saisie.quantite} ${saisie.produit.label} entrés à '
          '${magasin.label}.';
    });
  }

  Future<void> _transfert(
    BuildContext context,
    WidgetRef ref,
    StockPlace depart,
    List<StockPlace> magasins,
  ) async {
    final autres = [for (final m in magasins) if (m.id != depart.id) m];
    if (autres.isEmpty) return;
    final saisie = await showDialog<_Saisie>(
      context: context,
      builder: (_) => _SaisieDialog(
        titre: 'Transfert depuis ${depart.label}',
        entree: false,
        destinations: autres,
        depart: depart,
      ),
    );
    if (saisie == null || !context.mounted) return;
    await _faire(context, () async {
      await ref
          .read(stockRepositoryProvider)
          .requestTransfer(
            fromPlaceId: depart.id,
            toPlaceId: saisie.destination!.id,
            productId: saisie.produit.id,
            quantity: saisie.quantite,
            reason: saisie.motif,
            by: ref.read(sessionProvider).agent?.id,
          );
      return 'Transfert vers ${saisie.destination!.label} demandé : il attend '
          'la validation du contrôleur ou du comptable.';
    });
  }
}

/// Lance un geste et dit ce qu'il a donne.
Future<void> _faire(BuildContext context, Future<String> Function() geste) async {
  try {
    final message = await geste();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

// --- Les produits d'un magasin ------------------------------------------------

class _Lignes extends ConsumerWidget {
  const _Lignes({required this.magasin});

  final StockPlace magasin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lignes = ref.watch(
      stockLinesProvider((placeId: magasin.id, all: magasin.isCentral)),
    );
    return lignes.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text('$e'),
      data: (liste) {
        if (liste.isEmpty) {
          return EmptyState(
            icon: PhosphorIconsLight.archive,
            title: 'Rien en stock ici',
            message: magasin.isCentral
                ? 'Aucun produit n’existe encore.'
                : 'Demandez un transfert depuis l’économat.',
          );
        }
        final alertes = liste.where((l) => l.isNegative || l.isLow).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (alertes > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  '$alertes produit${alertes > 1 ? 's' : ''} à ravitailler ou à '
                  'corriger',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AtriumColors.warning,
                  ),
                ),
              ),
            for (final l in liste) _Ligne(ligne: l),
          ],
        );
      },
    );
  }
}

class _Ligne extends StatelessWidget {
  const _Ligne({required this.ligne});

  final StockLine ligne;

  @override
  Widget build(BuildContext context) {
    final l = ligne;
    final couleur = l.isNegative
        ? AtriumColors.error
        : l.isLow
        ? AtriumColors.warning
        : AtriumColors.textPrimary;
    return HoverRow(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AtriumColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l.minStock > 0
                      ? '${l.reference} · seuil ${l.minStock}'
                      : l.reference,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12.5,
                    color: AtriumColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (l.isNegative)
            Tag('Négatif', color: AtriumColors.error)
          else if (l.isLow)
            Tag('Stock bas', color: AtriumColors.warning),
          const SizedBox(width: 14),
          SizedBox(
            width: 90,
            child: Text(
              '${l.quantity} ${l.unit}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: couleur,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Les transferts a valider -------------------------------------------------

class _AValider extends ConsumerWidget {
  const _AValider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transferts = ref.watch(pendingTransfersProvider).value ?? const [];
    if (transferts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'À valider (${transferts.length})',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AtriumColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          for (final t in transferts) _Transfert(transfert: t),
        ],
      ),
    );
  }
}

class _Transfert extends ConsumerWidget {
  const _Transfert({required this.transfert});

  final PendingTransfer transfert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = transfert;
    final rouge = Theme.of(context).colorScheme.error;
    final vide = t.availableAtSource < t.quantity;
    return HoverRow(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        runSpacing: 10,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${t.quantity} ${t.unit} · ${t.productLabel}',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AtriumColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${t.fromLabel} → ${t.toLabel}'
                '${vide ? ' · ${t.fromLabel} n’en a que ${t.availableAtSource}' : ''}',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13,
                  fontWeight: vide ? FontWeight.w700 : FontWeight.w500,
                  color: vide ? AtriumColors.warning : AtriumColors.textSecondary,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: rouge,
                  side: BorderSide(color: rouge, width: 1.5),
                  minimumSize: const Size(0, 40),
                ),
                onPressed: () => _decider(context, ref, approuve: false),
                child: const Text('Refuser'),
              ),
              const SizedBox(width: 10),
              PillButton(
                label: 'Valider',
                icon: PhosphorIconsLight.check,
                tone: PillTone.accent,
                compact: true,
                onPressed: () => _decider(context, ref, approuve: true),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _decider(
    BuildContext context,
    WidgetRef ref, {
    required bool approuve,
  }) async {
    final t = transfert;
    final motif = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(approuve ? 'Valider le transfert' : 'Refuser le transfert'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${t.quantity} ${t.unit} de ${t.productLabel}, de '
                '${t.fromLabel} vers ${t.toLabel}.'
                '${approuve && t.availableAtSource < t.quantity ? '\n\n${t.fromLabel} n’en a que ${t.availableAtSource} : son stock passera sous zéro.' : ''}',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: motif,
                maxLength: 255,
                decoration: const InputDecoration(labelText: 'Motif (facultatif)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Retour'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(approuve ? 'Valider' : 'Refuser'),
          ),
        ],
      ),
    );
    final note = motif.text;
    motif.dispose();
    if (ok != true || !context.mounted) return;
    await _faire(context, () async {
      final depot = ref.read(stockRepositoryProvider);
      final agent = ref.read(sessionProvider).agent?.id;
      if (approuve) {
        await depot.approve(t.id, note: note, by: agent);
        return 'Transfert validé : ${t.toLabel} reçoit ${t.quantity} ${t.unit}.';
      }
      await depot.reject(t.id, note: note, by: agent);
      return 'Transfert refusé.';
    });
  }
}

// --- La saisie d'une entree ou d'un transfert ---------------------------------

class _Saisie {
  const _Saisie({
    required this.produit,
    required this.quantite,
    this.prixAchat = 0,
    this.destination,
    this.motif,
  });

  final StockProduct produit;
  final int quantite;
  final int prixAchat;
  final StockPlace? destination;
  final String? motif;
}

class _SaisieDialog extends ConsumerStatefulWidget {
  const _SaisieDialog({
    required this.titre,
    required this.entree,
    this.destinations = const [],
    this.depart,
  });

  final String titre;

  /// Une entree (prix d'achat) ou un transfert (destination).
  final bool entree;
  final List<StockPlace> destinations;
  final StockPlace? depart;

  @override
  ConsumerState<_SaisieDialog> createState() => _SaisieDialogState();
}

class _SaisieDialogState extends ConsumerState<_SaisieDialog> {
  StockProduct? _produit;
  StockPlace? _destination;
  final _quantite = TextEditingController();
  final _prix = TextEditingController();
  final _motif = TextEditingController();

  @override
  void dispose() {
    _quantite.dispose();
    _prix.dispose();
    _motif.dispose();
    super.dispose();
  }

  int get _q => int.tryParse(_quantite.text.trim()) ?? 0;

  bool get _pret =>
      _produit != null && _q > 0 && (widget.entree || _destination != null);

  @override
  Widget build(BuildContext context) {
    final produits = ref.watch(stockProductsProvider).value ?? const [];
    return AlertDialog(
      scrollable: true,
      title: Text(widget.titre),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<StockProduct>(
              initialValue: _produit,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Produit'),
              items: [
                for (final p in produits)
                  DropdownMenuItem(value: p, child: Text('${p.label} (${p.unit})')),
              ],
              onChanged: (p) => setState(() {
                _produit = p;
                if (widget.entree && p != null && _prix.text.isEmpty) {
                  _prix.text = p.purchasePrice > 0 ? '${p.purchasePrice}' : '';
                }
              }),
            ),
            if (!widget.entree) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<StockPlace>(
                initialValue: _destination,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Vers'),
                items: [
                  for (final m in widget.destinations)
                    DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (m) => setState(() => _destination = m),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _quantite,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Quantité',
                suffixText: _produit?.unit,
              ),
            ),
            if (widget.entree) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _prix,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Prix d’achat unitaire',
                  suffixText: 'FCFA',
                ),
              ),
            ],
            if (!widget.entree && _produit != null && widget.depart != null)
              _DisponibleAuDepart(
                magasin: widget.depart!,
                produitId: _produit!.id,
                demande: _q,
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _motif,
              maxLength: 255,
              decoration: InputDecoration(
                labelText: widget.entree
                    ? 'Fournisseur, bon de livraison (facultatif)'
                    : 'Motif (facultatif)',
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
        FilledButton(
          onPressed: !_pret
              ? null
              : () => Navigator.of(context).pop(
                  _Saisie(
                    produit: _produit!,
                    quantite: _q,
                    prixAchat: int.tryParse(_prix.text.trim()) ?? 0,
                    destination: _destination,
                    motif: _motif.text.trim().isEmpty ? null : _motif.text.trim(),
                  ),
                ),
          child: Text(widget.entree ? 'Enregistrer l’entrée' : 'Demander le transfert'),
        ),
      ],
    );
  }
}

/// Ce que le magasin de depart a : le transfert reste possible au-dela, mais
/// celui qui le demande le sait.
class _DisponibleAuDepart extends ConsumerWidget {
  const _DisponibleAuDepart({
    required this.magasin,
    required this.produitId,
    required this.demande,
  });

  final StockPlace magasin;
  final String produitId;
  final int demande;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lignes =
        ref
            .watch(stockLinesProvider((placeId: magasin.id, all: true)))
            .value ??
        const <StockLine>[];
    final ligne = lignes.where((l) => l.productId == produitId).firstOrNull;
    final dispo = ligne?.quantity ?? 0;
    final manque = demande > dispo;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        manque
            ? '${magasin.label} n’en a que $dispo : son stock passera sous zéro '
                  'si le transfert est validé.'
            : '${magasin.label} en a $dispo.',
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: manque ? FontWeight.w700 : FontWeight.w500,
          color: manque ? AtriumColors.warning : AtriumColors.textSecondary,
        ),
      ),
    );
  }
}
