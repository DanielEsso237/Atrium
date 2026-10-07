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
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database.dart';
import '../../data/repositories/folio_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import 'add_charge_dialog.dart';
import 'cash_dialog.dart';
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

enum _Filtre { ouvertes, aEncaisser, closes, toutes }

class _FiltreFolios extends Notifier<_Filtre> {
  @override
  _Filtre build() => _Filtre.ouvertes;

  void choisir(_Filtre f) => state = f;
}

final _filtreProvider = NotifierProvider<_FiltreFolios, _Filtre>(
  _FiltreFolios.new,
);

class _FolioChoisi extends Notifier<String?> {
  @override
  String? build() => null;

  void choisir(String? id) => state = id;
}

final _folioChoisiProvider = NotifierProvider<_FolioChoisi, String?>(
  _FolioChoisi.new,
);

bool _garde(_Filtre f, FolioSummary x) => switch (f) {
  _Filtre.ouvertes => x.isOpen,
  _Filtre.aEncaisser => x.balance > 0,
  _Filtre.closes => !x.isOpen,
  _Filtre.toutes => true,
};

class FoliosScreen extends ConsumerWidget {
  const FoliosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folios = ref.watch(foliosProvider);
    final filtre = ref.watch(_filtreProvider);
    final toutes = folios.value ?? const <FolioSummary>[];
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    final ouvertes = toutes.where((f) => f.isOpen).toList();
    final du = toutes.fold<int>(
      0,
      (t, f) => t + (f.balance > 0 ? f.balance : 0),
    );
    final encaisse = ouvertes.fold<int>(0, (t, f) => t + f.paymentsTotal);

    return ModuleScaffold(
      title: 'Factures',
      subtitle:
          '${ouvertes.length} ardoise${ouvertes.length > 1 ? 's' : ''} '
          'ouverte${ouvertes.length > 1 ? 's' : ''}, '
          '${formatAmount(du)} restent à encaisser',
      // La caisse vit ici : c'est le module ou l'argent passe, et la prise de
      // poste comme la fin de service s'y font naturellement.
      action: const CashButton(),
      body: folios.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: PhosphorIconsLight.warningCircle,
          title: 'Lecture impossible',
          message: '$e',
        ),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: PhosphorIconsLight.receipt,
              title: 'Aucune ardoise',
              message: "Elles s'ouvrent toutes seules à l'arrivée d'un client.",
            );
          }
          final visibles = list.where((f) => _garde(filtre, f)).toList();
          final filtres = FilterPills<_Filtre>(
            selected: filtre,
            onChanged: (f) => ref.read(_filtreProvider.notifier).choisir(f),
            options: [
              FilterOption(
                _Filtre.ouvertes,
                'Ouvertes',
                count: list.where((f) => _garde(_Filtre.ouvertes, f)).length,
              ),
              FilterOption(
                _Filtre.aEncaisser,
                'À encaisser',
                count: list.where((f) => _garde(_Filtre.aEncaisser, f)).length,
                color: AtriumColors.error,
              ),
              FilterOption(
                _Filtre.closes,
                'Closes',
                count: list.where((f) => _garde(_Filtre.closes, f)).length,
              ),
              FilterOption(_Filtre.toutes, 'Toutes', count: list.length),
            ],
          );

          return LayoutBuilder(
            builder: (context, c) {
              final large = c.maxWidth >= 900;
              final colonne = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      marge,
                      0,
                      large ? 0 : marge,
                      12,
                    ),
                    child: _Bandeau(du: du, encaisse: encaisse),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      marge,
                      0,
                      large ? 0 : marge,
                      12,
                    ),
                    child: filtres,
                  ),
                  Expanded(
                    child: visibles.isEmpty
                        ? const EmptyState(
                            icon: PhosphorIconsLight.checks,
                            title: 'Rien dans ce filtre',
                          )
                        : _ListeFolios(
                            folios: visibles,
                            large: large,
                            padding: EdgeInsets.fromLTRB(
                              marge,
                              0,
                              large ? 0 : marge,
                              32,
                            ),
                          ),
                  ),
                ],
              );
              if (!large) return colonne;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 420, child: colonne),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(0, 0, marge, 24),
                      child: const _PanneauFolio(),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Deux chiffres en tete de liste : ce qui reste du, ce qui est deja rentre.
class _Bandeau extends StatelessWidget {
  const _Bandeau({required this.du, required this.encaisse});

  final int du;
  final int encaisse;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    Widget chiffre(String libelle, int montant, Color couleur) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            libelle,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.onHeroSoft,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatAmount(montant),
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.8,
                color: couleur,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
        ],
      ),
    );
    return FadeUp(
      child: Bezel(
        core: p.hero,
        radius: 24,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Row(
          children: [
            chiffre('Reste à encaisser', du, p.heroAccent),
            Container(
              width: 1,
              height: 40,
              margin: const EdgeInsets.symmetric(horizontal: 14),
              color: p.onHero.withValues(alpha: 0.14),
            ),
            chiffre('Déjà encaissé', encaisse, p.onHero),
          ],
        ),
      ),
    );
  }
}

class _ListeFolios extends ConsumerWidget {
  const _ListeFolios({
    required this.folios,
    required this.large,
    required this.padding,
  });

  final List<FolioSummary> folios;
  final bool large;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choisi = ref.watch(_folioChoisiProvider);
    return ListView.builder(
      padding: padding,
      itemCount: folios.length,
      itemBuilder: (context, i) {
        final f = folios[i];
        return FadeUp(
          index: i.clamp(0, 8),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _LigneFolio(
              folio: f,
              choisie: large && choisi == f.id,
              onTap: () {
                if (large) {
                  ref.read(_folioChoisiProvider.notifier).choisir(f.id);
                } else {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    showDragHandle: false,
                    builder: (_) => FractionallySizedBox(
                      heightFactor: 0.92,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(30),
                        ),
                        child: Material(
                          color: AtriumColors.background,
                          child: _FolioDetail(folio: f, fermable: true),
                        ),
                      ),
                    ),
                  );
                }
              },
            ),
          ),
        );
      },
    );
  }
}

class _LigneFolio extends StatelessWidget {
  const _LigneFolio({
    required this.folio,
    required this.choisie,
    required this.onTap,
  });

  final FolioSummary folio;
  final bool choisie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    // Un solde du se voit de loin ; une ardoise soldee n'a pas besoin
    // d'attirer l'oeil.
    final couleur = folio.balance > 0
        ? p.error
        : (folio.isOpen ? p.success : p.textSecondary);
    return AnimatedContainer(
      duration: AtriumMotion.of(context, const Duration(milliseconds: 320)),
      curve: atriumSpring,
      decoration: BoxDecoration(
        color: choisie ? p.accent.withValues(alpha: 0.12) : p.paper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: choisie ? p.accent : p.border),
      ),
      child: HoverRow(
        onTap: onTap,
        radius: 20,
        padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.surfaceMuted,
                borderRadius: BorderRadius.circular(14),
              ),
              child: folio.roomNumber != null
                  ? Text(
                      folio.roomNumber!,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        fontFeatures: tabularFigures,
                      ),
                    )
                  : Icon(PhosphorIconsLight.receipt, size: 20, color: p.text),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folio.guestName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                  Text(
                    folio.isOpen ? folio.number : '${folio.number} (close)',
                    style: atriumCode(
                      12,
                      color: p.textSecondary,
                      weight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatAmount(folio.balance),
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: folio.balance > 0 ? couleur : p.text,
                    fontFeatures: tabularFigures,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: couleur,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      folio.balance > 0
                          ? 'reste dû'
                          : (folio.isOpen ? 'soldée' : 'close'),
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 12,
                        color: p.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PanneauFolio extends ConsumerWidget {
  const _PanneauFolio();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(_folioChoisiProvider);
    final folio = id == null
        ? null
        : ref.watch(foliosProvider).value?.where((f) => f.id == id).firstOrNull;
    return Bezel(
      radius: 30,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AnimatedSwitcher(
          duration: AtriumMotion.of(context, const Duration(milliseconds: 380)),
          switchInCurve: atriumSpring,
          child: folio == null
              ? const EmptyState(
                  key: ValueKey('vide'),
                  icon: PhosphorIconsLight.receipt,
                  title: 'Choisissez une ardoise',
                  message:
                      'Consommations, encaissements, facture et clôture '
                      's’y font ici.',
                )
              : _FolioDetail(
                  key: ValueKey(folio.id),
                  folio: folio,
                  fermable: false,
                ),
        ),
      ),
    );
  }
}

/// Le detail d'une ardoise, lu comme un ticket : le solde en grand, puis ce
/// qui a ete porte, puis ce qui a ete paye.
class _FolioDetail extends ConsumerWidget {
  const _FolioDetail({super.key, required this.folio, required this.fermable});

  final FolioSummary folio;
  final bool fermable;

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
    final p = AtriumPalette.current;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 16, 22),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [p.heroTop, p.hero],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: current.number,
                                  style: atriumCode(13, color: p.onHeroSoft),
                                ),
                                if (current.roomNumber != null)
                                  TextSpan(
                                    text: ', chambre ${current.roomNumber}',
                                  ),
                              ],
                            ),
                            style: TextStyle(
                              fontFamily: atriumFontFamily,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: p.onHeroSoft,
                              fontFeatures: tabularFigures,
                            ),
                          ),
                        ),
                        if (fermable)
                          IconButton(
                            tooltip: 'Fermer',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.08,
                              ),
                            ),
                            icon: Icon(PhosphorIconsLight.x, color: p.onHero),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      current.guestName,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                        color: p.onHero,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      current.balance > 0 ? 'Reste dû' : 'Solde',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13,
                        color: p.onHeroSoft,
                      ),
                    ),
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: current.balance.toDouble()),
                      duration: AtriumMotion.of(
                        context,
                        const Duration(milliseconds: 700),
                      ),
                      curve: atriumSpring,
                      builder: (_, v, _) => Text(
                        formatAmount(v.round()),
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 42,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1.6,
                          height: 1.1,
                          color: current.balance > 0 ? p.heroAccent : p.onHero,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${formatAmount(current.chargesTotal)} porté, '
                      '${formatAmount(current.paymentsTotal)} encaissé',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: p.onHeroSoft,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(
                      titre: 'Consommations',
                      compteur: items.value?.length,
                      enfant: items.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => Text('$e'),
                        data: (lignes) => lignes.isEmpty
                            ? _Vide('Rien de porté à cette ardoise.')
                            : Column(
                                children: [
                                  for (final l in lignes)
                                    _Line(
                                      label: l.label,
                                      detail:
                                          '${chargeCategoryLabel(l.category)}, ${_jour(l.businessDate)}'
                                          '${l.quantity > 1 ? ', quantité ${l.quantity}' : ''}',
                                      amount: l.amount,
                                    ),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _Section(
                      titre: 'Encaissements',
                      compteur: payments.value?.length,
                      enfant: payments.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => Text('$e'),
                        data: (lignes) => lignes.isEmpty
                            ? _Vide('Aucun encaissement.')
                            : Column(
                                children: [
                                  for (final pay in lignes)
                                    _Line(
                                      label: paymentMethodLabel(pay.method),
                                      detail: pay.reference ?? '',
                                      amount: pay.amount,
                                      paiement: true,
                                    ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _Actions(folio: current),
      ],
    );
  }
}

String _jour(String iso) {
  final d = parseIsoDate(iso);
  return d == null ? iso : formatDayMonth(d);
}

class _Vide extends StatelessWidget {
  const _Vide(this.texte);

  final String texte;

  @override
  Widget build(BuildContext context) => Text(
    texte,
    style: TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14,
      color: AtriumColors.textSecondary,
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.titre, required this.enfant, this.compteur});

  final String titre;
  final Widget enfant;
  final int? compteur;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Eyebrow(
        titre,
        trailing: compteur == null
            ? null
            : Text(
                '$compteur',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AtriumColors.textSecondary,
                ),
              ),
      ),
      const SizedBox(height: 8),
      enfant,
    ],
  );
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.folio});

  final FolioSummary folio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    if (!folio.isOpen) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: p.paper,
          border: Border(top: BorderSide(color: p.border)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              PhosphorIconsLight.lockSimple,
              size: 18,
              color: p.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              'Ardoise close : plus rien ne peut y être porté.',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 14,
                color: p.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    final boutons = <Widget>[
      PillButton(
        label: 'Encaisser',
        icon: PhosphorIconsLight.coins,
        tone: PillTone.accent,
        compact: true,
        expand: true,
        onPressed: folio.balance <= 0 ? null : () => _encaisser(context, ref),
      ),
      PillButton(
        label: 'Consommation',
        icon: PhosphorIconsLight.plus,
        tone: PillTone.quiet,
        compact: true,
        expand: true,
        onPressed: () => showAddChargeDialog(
          context,
          folioId: folio.id,
          guestName: folio.guestName,
        ),
      ),
      // Editer avant d'encaisser est legitime : le client veut voir ce qu'il
      // doit avant de payer.
      PillButton(
        label: 'Facture',
        icon: PhosphorIconsLight.receipt,
        tone: PillTone.quiet,
        compact: true,
        expand: true,
        onPressed: () => showInvoiceDialog(
          context,
          ref,
          folioId: folio.id,
          guestName: folio.guestName,
        ),
      ),
      // Une ardoise close avec un impaye est une creance que plus personne
      // ne verra : la cloture attend un solde nul.
      PillButton(
        label: 'Clore',
        icon: PhosphorIconsLight.lockSimple,
        tone: PillTone.quiet,
        compact: true,
        expand: true,
        onPressed: folio.balance != 0 ? null : () => _clore(context, ref),
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: p.paper,
        border: Border(top: BorderSide(color: p.border)),
      ),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth < 560) {
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final b in boutons)
                    SizedBox(width: (c.maxWidth - 8) / 2, child: b),
                ],
              );
            }
            return Row(
              children: [
                for (var i = 0; i < boutons.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: boutons[i]),
                ],
              ],
            );
          },
        ),
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

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.amount,
    this.detail,
    this.paiement = false,
  });

  final String label;
  final String? detail;
  final int amount;
  final bool paiement;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                if (detail != null && detail!.isNotEmpty)
                  Text(
                    detail!,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 12.5,
                      color: p.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            formatAmount(amount),
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: paiement ? p.success : p.text,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}
