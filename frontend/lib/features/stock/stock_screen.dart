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
///
/// L'ecran dit l'etat reel de chaque produit, en chiffres exacts : en
/// haut, une carte par etat (en stock, stock bas, rupture, negatif) ; en
/// dessous, une carte par produit avec sa quantite, son seuil et ce qu'il
/// manque. La recherche et les filtres d'etat trouvent le reste.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/fenetre_motif.dart';
import '../../core/formats.dart';
import '../../core/recherche.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/stock_repository.dart';
import '../auth/session.dart';
import 'mouvement_stock_screen.dart';
import '../../core/ui/confirmation.dart';

class _MagasinChoisi extends Notifier<String?> {
  @override
  String? build() => null;

  void choisir(String id) => state = id;
}

final _magasinChoisiProvider = NotifierProvider<_MagasinChoisi, String?>(
  _MagasinChoisi.new,
);

/// L'etat reel d'un produit dans un magasin, tel que le dit sa quantite :
/// rien d'estime, rien d'arrondi.
enum _Etat {
  tous('Tous'),
  enStock('En stock'),
  bas('Stock bas'),
  rupture('Rupture'),
  negatif('Négatif');

  const _Etat(this.libelle);
  final String libelle;

  Color couleur(AtriumPalette p) => switch (this) {
    _Etat.tous => p.textSecondary,
    _Etat.enStock => p.success,
    _Etat.bas => p.warning,
    _Etat.rupture || _Etat.negatif => p.error,
  };
}

/// L'ordre de la liste : ce qui manque d'abord, par defaut.
enum _Tri {
  urgence('Urgence'),
  nom('Nom'),
  quantite('Quantité');

  const _Tri(this.libelle);
  final String libelle;
}

/// Deux lectures des memes produits : le tableau pour comparer d'un coup
/// d'oeil, les cartes pour lire un produit a la fois (demande du 15
/// octobre). Le tableau par defaut.
enum _Vue { liste, cartes }

/// Garde le choix tant que l'application tourne : on change de magasin, on
/// part valider un transfert, on revient sur la meme vue.
class _VueStock extends Notifier<_Vue> {
  @override
  _Vue build() => _Vue.liste;

  void choisir(_Vue v) => state = v;
}

final _vueStockProvider = NotifierProvider<_VueStock, _Vue>(_VueStock.new);

extension on StockLine {
  /// Negatif : moins que rien, une vente a ete faite sans stock. Rupture :
  /// plus rien. Bas : moins que le seuil fixe par l'econome.
  _Etat get etat {
    if (quantity < 0) return _Etat.negatif;
    if (quantity == 0) return _Etat.rupture;
    if (minStock > 0 && quantity < minStock) return _Etat.bas;
    return _Etat.enStock;
  }

  /// Plus c'est petit, plus c'est urgent : negatif, rupture, puis sous le
  /// seuil (le plus loin du seuil d'abord), puis le reste.
  double get urgence => switch (etat) {
    _Etat.negatif => -3e9 + quantity,
    _Etat.rupture => -2e9,
    _Etat.bas => -1e9 + quantity / minStock,
    _ => 0,
  };

  bool garde(_Etat e) => e == _Etat.tous || etat == e;
}

class StockScreen extends ConsumerStatefulWidget {
  const StockScreen({super.key});

  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen> {
  String _recherche = '';
  _Etat _etat = _Etat.tous;
  _Tri _tri = _Tri.urgence;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final magasins = ref.watch(stockPlacesProvider(session.agent?.id));
    // Tous les magasins de l'hotel : ceux d'ou un point de vente peut se
    // ravitailler, meme s'il ne les voit pas dans ses onglets.
    final tousLesMagasins = ref.watch(stockPlacesProvider(null)).value;
    final acces = session.acces;
    // Deux gestes, deux droits, comme la route du serveur : l'econome fait
    // entrer les livraisons, le point de vente ne fait que demander.
    final peutGerer = acces.peut('stock.manage');
    final peutDemander = acces.peut('stock.transfer.request');
    final peutValider = acces.peut('stock.transfer.approve');
    // La valeur du stock s'ouvre a l'econome et a la comptabilite, comme
    // `/accounting/stock-value` sur le serveur.
    final voitValeur = peutGerer || acces.peut('accounting.read');

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
        final lignes = ref
            .watch(
              stockLinesProvider((placeId: magasin.id, all: magasin.isCentral)),
            );

        void ravitailler(StockLine l) => magasin.isCentral && peutGerer
            ? _entree(context, ref, magasin, produitId: l.productId)
            : _transfert(context, ref, magasin, tousLesMagasins ?? liste,
                produitId: l.productId);

        return ModuleScaffold(
          title: 'Stocks',
          subtitle: magasin.isCentral
              ? 'L’économat ravitaille les points de vente'
              : 'Stock du point de vente ${magasin.label}',
          action: peutGerer || peutDemander
              ? Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    if (peutGerer && magasin.isCentral)
                      PillButton(
                        label: 'Entrée',
                        icon: PhosphorIconsLight.plus,
                        tone: PillTone.accent,
                        onPressed: () => _entree(context, ref, magasin),
                      ),
                    // Utilise ou perdu, dans n'importe quel magasin : le bar
                    // casse aussi des bouteilles (demande du 15 octobre).
                    if (peutGerer)
                      PillButton(
                        label: 'Sortie',
                        icon: PhosphorIconsLight.minus,
                        tone: PillTone.quiet,
                        onPressed: () => _sortie(context, ref, magasin),
                      ),
                    if (peutDemander)
                      PillButton(
                        label: 'Transfert',
                        icon: PhosphorIconsLight.arrowsLeftRight,
                        tone: PillTone.quiet,
                        onPressed: () => _transfert(
                          context,
                          ref,
                          magasin,
                          tousLesMagasins ?? liste,
                        ),
                      ),
                  ],
                )
              : null,
          body: ListView(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
            children: [
              _ChoixMagasin(
                magasins: liste,
                choisi: magasin,
                onChoisi: (m) {
                  ref.read(_magasinChoisiProvider.notifier).choisir(m.id);
                  setState(() => _etat = _Etat.tous);
                },
              ),
              const SizedBox(height: 16),
              ...lignes.when(
                loading: () => const [
                  Padding(
                    padding: EdgeInsets.all(48),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
                error: (e, _) => [Text('$e')],
                data: (toutes) => _contenu(
                  magasin: magasin,
                  toutes: toutes,
                  peutValider: peutValider,
                  peutGerer: peutGerer,
                  voitValeur: voitValeur,
                  onRavitailler: (magasin.isCentral ? peutGerer : peutDemander)
                      ? ravitailler
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _contenu({
    required StockPlace magasin,
    required List<StockLine> toutes,
    required bool peutValider,
    required bool peutGerer,
    required bool voitValeur,
    required void Function(StockLine)? onRavitailler,
  }) {
    if (toutes.isEmpty) {
      return [
        if (peutValider || peutGerer)
          _AValider(valide: peutValider, ajuste: peutGerer),
        EmptyState(
          icon: PhosphorIconsLight.archive,
          title: 'Rien en stock ici',
          message: magasin.isCentral
              ? 'Aucun produit n’existe encore.'
              : 'Demandez un transfert depuis l’économat.',
        ),
      ];
    }
    final p = AtriumPalette.current;
    final vue = ref.watch(_vueStockProvider);
    final recherche = Recherche(_recherche);
    final trouvees = [
      for (final l in toutes)
        if (recherche.garde([l.label, l.reference, l.unit, l.etat.libelle])) l,
    ];
    int nombre(_Etat e) => trouvees.where((l) => l.garde(e)).length;
    final montrees = [
      for (final l in trouvees)
        if (l.garde(_etat)) l,
    ]..sort(switch (_tri) {
        _Tri.urgence => (a, b) {
          final u = a.urgence.compareTo(b.urgence);
          return u != 0 ? u : a.label.compareTo(b.label);
        },
        _Tri.nom => (a, b) => a.label.compareTo(b.label),
        _Tri.quantite => (a, b) => b.quantity.compareTo(a.quantity),
      });

    return [
      _Chiffres(
        lignes: toutes,
        voitValeur: voitValeur,
        etat: _etat,
        onEtat: (e) => setState(() => _etat = e),
      ),
      const SizedBox(height: 20),
      if (peutValider || peutGerer)
        _AValider(valide: peutValider, ajuste: peutGerer),
      LayoutBuilder(
        builder: (context, c) {
          final recherchePill = SearchPill(
            hint: 'Produit, référence, état…',
            onChanged: (v) => setState(() => _recherche = v),
          );
          final tri = _MenuTri(
            tri: _tri,
            onChoisi: (t) => setState(() => _tri = t),
          );
          final filtres = FilterPills<_Etat>(
            selected: _etat,
            onChanged: (e) => setState(() => _etat = e),
            options: [
              for (final e in _Etat.values)
                FilterOption(
                  e,
                  e.libelle,
                  count: nombre(e),
                  color: e == _Etat.tous ? null : e.couleur(p),
                ),
            ],
          );
          final choixVue = _ChoixVue(
            vue: vue,
            compact: c.maxWidth < 700,
            onChoisi: ref.read(_vueStockProvider.notifier).choisir,
          );
          if (c.maxWidth >= 1240) {
            return Row(
              children: [
                SizedBox(width: 300, child: recherchePill),
                const SizedBox(width: 12),
                Expanded(child: filtres),
                const SizedBox(width: 12),
                tri,
                const SizedBox(width: 10),
                choixVue,
              ],
            );
          }
          if (c.maxWidth < 600) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                recherchePill,
                const SizedBox(height: 10),
                Row(children: [tri, const Spacer(), choixVue]),
                const SizedBox(height: 10),
                filtres,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: recherchePill),
                  const SizedBox(width: 10),
                  tri,
                  const SizedBox(width: 10),
                  choixVue,
                ],
              ),
              const SizedBox(height: 10),
              filtres,
            ],
          );
        },
      ),
      const SizedBox(height: 16),
      if (montrees.isEmpty)
        EmptyState(
          icon: PhosphorIconsLight.magnifyingGlass,
          title: 'Aucun produit ne correspond',
          message: recherche.vide
              ? 'Aucun produit dans cet état ici.'
              : 'Vérifiez l’orthographe, ou cherchez par référence.',
        )
      else
        // Un fondu au changement de vue : la reponse au geste, rien de plus.
        AnimatedSwitcher(
          duration: AtriumMotion.of(context, AtriumMotion.base),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (actuel, anciens) => Stack(
            alignment: Alignment.topCenter,
            children: [...anciens, ?actuel],
          ),
          child: vue == _Vue.liste
              ? _TableauProduits(
                  key: const ValueKey(_Vue.liste),
                  lignes: montrees,
                  voitValeur: voitValeur,
                  tri: _tri,
                  onTri: (t) => setState(() => _tri = t),
                  onRavitailler: onRavitailler,
                )
              : _GrilleProduits(
                  key: const ValueKey(_Vue.cartes),
                  lignes: montrees,
                  voitValeur: voitValeur,
                  onRavitailler: onRavitailler,
                ),
        ),
    ];
  }

  Future<void> _entree(
    BuildContext context,
    WidgetRef ref,
    StockPlace magasin, {
    String? produitId,
  }) async {
    // Plusieurs produits d'un coup, en plein ecran (15 octobre).
    await ouvrirMouvementStock(
      context,
      entree: true,
      magasin: magasin,
      produitId: produitId,
    );
  }

  Future<void> _sortie(
    BuildContext context,
    WidgetRef ref,
    StockPlace magasin, {
    String? produitId,
  }) async {
    final saisie = await showDialog<_Saisie>(
      context: context,
      builder: (_) => _SaisieDialog(
        titre: 'Sortie de ${magasin.label}',
        entree: false,
        sortie: true,
        depart: magasin,
        produitId: produitId,
      ),
    );
    if (saisie == null || !context.mounted) return;
    await _faire(context, () async {
      await ref
          .read(stockRepositoryProvider)
          .sortir(
            placeId: magasin.id,
            productId: saisie.produit.id,
            quantity: saisie.quantite,
            perte: saisie.perte,
            reason: saisie.motif ?? '',
            by: ref.read(sessionProvider).agent?.id,
          );
      return '${saisie.quantite} ${saisie.produit.label} sortis de '
          '${magasin.label} (${saisie.perte ? 'perte' : 'utilisation'}).';
    });
  }

  Future<void> _transfert(
    BuildContext context,
    WidgetRef ref,
    StockPlace depart,
    List<StockPlace> magasins, {
    String? produitId,
  }) async {
    // Tous les magasins de l'hotel, pas seulement ceux de l'agent : le
    // barman ne voit que son bar, et ne se ravitaillait donc depuis rien --
    // le bouton ne faisait rien, sans un mot (vecu le 11 octobre).
    // Sur l'onglet d'un point de vente, on demande son ravitaillement : il
    // recoit, depuis l'economat ou un autre point de vente. Sur celui de
    // l'economat, on transfere vers un point de vente.
    final ravitaillement = !depart.isCentral;
    final autres = [
      for (final m in magasins)
        if (m.id != depart.id) m,
    ]..sort((a, b) => (b.isCentral ? 1 : 0).compareTo(a.isCentral ? 1 : 0));
    if (autres.isEmpty) {
      montrerRefus(context, 'Aucun autre magasin connu sur cette tablette : lancez une '
            'synchronisation.');
      return;
    }
    await ouvrirMouvementStock(
      context,
      entree: false,
      magasin: depart,
      autres: autres,
      ravitaillement: ravitaillement,
      produitId: produitId,
    );
  }
}

/// Lance un geste et dit ce qu'il a donne.
Future<void> _faire(BuildContext context, Future<String> Function() geste) async {
  try {
    final message = await geste();
    if (context.mounted) {
      montrerSucces(context, message);
    }
  } on StateError catch (e) {
    if (context.mounted) {
      montrerRefus(context, e.message);
    }
  }
}

// --- Le magasin ---------------------------------------------------------------

/// Le magasin affiche, en menu : une quinzaine de magasins ne tiennent pas
/// en pastilles sur une ligne. L'economat d'abord.
class _ChoixMagasin extends StatelessWidget {
  const _ChoixMagasin({
    required this.magasins,
    required this.choisi,
    required this.onChoisi,
  });

  final List<StockPlace> magasins;
  final StockPlace choisi;
  final ValueChanged<StockPlace> onChoisi;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    if (magasins.length == 1) {
      return const SizedBox.shrink();
    }
    final tries = [...magasins]
      ..sort((a, b) {
        if (a.isCentral != b.isCentral) return a.isCentral ? -1 : 1;
        return a.label.compareTo(b.label);
      });
    IconData icone(StockPlace m) =>
        m.isCentral ? PhosphorIconsLight.archive : PhosphorIconsLight.storefront;

    return Align(
      alignment: Alignment.centerLeft,
      child: MenuAnchor(
        alignmentOffset: const Offset(0, 6),
        menuChildren: [
          for (final m in tries)
            MenuItemButton(
              leadingIcon: Icon(icone(m), size: 18),
              trailingIcon: m.id == choisi.id
                  ? Icon(PhosphorIconsLight.check, size: 18, color: p.accent)
                  : null,
              onPressed: () => onChoisi(m),
              child: Text(m.label),
            ),
        ],
        builder: (context, menu, _) => Material(
          color: p.paper,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtriumRadii.md),
            side: BorderSide(color: p.border),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(AtriumRadii.md),
            onTap: () => menu.isOpen ? menu.close() : menu.open(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: p.accentTint,
                      borderRadius: BorderRadius.circular(AtriumRadii.sm),
                    ),
                    child: Icon(icone(choisi), size: 19, color: p.accent),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        choisi.isCentral ? 'Magasin central' : 'Point de vente',
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 12,
                          color: p.textSecondary,
                        ),
                      ),
                      Text(
                        choisi.label,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Text(
                    '${magasins.length} magasins',
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 12.5,
                      color: p.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(PhosphorIconsLight.caretDown, size: 16, color: p.textSecondary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Les chiffres du magasin --------------------------------------------------

/// Les cartes du haut : un chiffre exact chacune. Toucher une carte d'etat
/// montre ces produits-la.
class _Chiffres extends StatelessWidget {
  const _Chiffres({
    required this.lignes,
    required this.voitValeur,
    required this.etat,
    required this.onEtat,
  });

  final List<StockLine> lignes;
  final bool voitValeur;
  final _Etat etat;
  final ValueChanged<_Etat> onEtat;

  @override
  Widget build(BuildContext context) {
    int nombre(_Etat e) => lignes.where((l) => l.etat == e).length;
    // Au prix d'achat de la fiche produit : le cout moyen reste au serveur.
    final valeur = lignes.fold<int>(
      0,
      (s, l) => s + math.max(0, l.quantity) * l.purchasePrice,
    );
    final cartes = <Widget>[
      _CarteChiffre(
        icone: PhosphorIconsLight.package,
        libelle: 'Produits suivis',
        valeur: '${lignes.length}',
        detail: 'dans ce magasin',
        choisie: etat == _Etat.tous,
        onTap: () => onEtat(_Etat.tous),
      ),
      for (final (e, icone, detail) in [
        (_Etat.enStock, PhosphorIconsLight.checkCircle, 'au niveau du seuil ou plus'),
        (_Etat.bas, PhosphorIconsLight.warningCircle, 'sous leur seuil'),
        (_Etat.rupture, PhosphorIconsLight.x, 'plus rien en magasin'),
        (_Etat.negatif, PhosphorIconsLight.warningDiamond, 'vendus sans stock'),
      ])
        _CarteChiffre(
          icone: icone,
          libelle: e.libelle,
          valeur: '${nombre(e)}',
          detail: detail,
          etat: nombre(e) > 0 ? e : null,
          choisie: etat == e,
          onTap: () => onEtat(e),
        ),
      if (voitValeur)
        _CarteChiffre(
          icone: PhosphorIconsLight.coins,
          libelle: 'Valeur du stock',
          valeur: formatAmount(valeur),
          detail: 'au prix d’achat',
        ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        const ecart = 12.0;
        final colonnes = c.maxWidth >= 1100
            ? cartes.length
            : c.maxWidth >= 700
            ? 3
            : 2;
        final largeur = (c.maxWidth - ecart * (colonnes - 1)) / colonnes;
        return Wrap(
          spacing: ecart,
          runSpacing: ecart,
          children: [
            for (final carte in cartes) SizedBox(width: largeur, child: carte),
          ],
        );
      },
    );
  }
}

/// Une carte blanche, toutes pareilles : l'etat ne vit que dans le badge.
class _CarteChiffre extends StatelessWidget {
  const _CarteChiffre({
    required this.icone,
    required this.libelle,
    required this.valeur,
    required this.detail,
    this.etat,
    this.choisie = false,
    this.onTap,
  });

  final IconData icone;
  final String libelle;
  final String valeur;
  final String detail;

  /// L'etat a signaler ; `null` quand il n'y a rien a dire.
  final _Etat? etat;
  final bool choisie;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final e = etat;
    return Semantics(
      button: onTap != null,
      selected: choisie,
      child: Material(
        color: p.paper,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtriumRadii.lg),
          side: BorderSide(
            color: choisie ? p.accent : p.border,
            width: choisie ? 1.6 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AtriumRadii.lg),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: p.accentTint,
                        borderRadius: BorderRadius.circular(AtriumRadii.sm),
                      ),
                      child: Icon(icone, size: 18, color: p.accent),
                    ),
                    const Spacer(),
                    if (e != null) _BadgeEtat(etat: e),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  valeur,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: p.text,
                    fontFeatures: tabularFigures,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  libelle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Le badge d'un etat : un voyant et son nom, sur un fond pale.
class _BadgeEtat extends StatelessWidget {
  const _BadgeEtat({required this.etat});

  final _Etat etat;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final c = etat.couleur(p);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            etat.libelle,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// Le choix de l'ordre de la liste.
class _MenuTri extends StatelessWidget {
  const _MenuTri({required this.tri, required this.onChoisi});

  final _Tri tri;
  final ValueChanged<_Tri> onChoisi;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        for (final t in _Tri.values)
          MenuItemButton(
            trailingIcon: t == tri
                ? Icon(PhosphorIconsLight.check, size: 18, color: p.accent)
                : null,
            onPressed: () => onChoisi(t),
            child: Text(t.libelle),
          ),
      ],
      builder: (context, menu, _) => Material(
        color: p.paper,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtriumRadii.md - 2),
          side: BorderSide(color: p.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AtriumRadii.md - 2),
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Trier par ${tri.libelle.toLowerCase()}',
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(PhosphorIconsLight.caretDown, size: 16, color: p.textSecondary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Les produits d'un magasin ------------------------------------------------

/// Les produits en cartes blanches, toutes de la meme taille.
class _GrilleProduits extends StatelessWidget {
  const _GrilleProduits({
    super.key,
    required this.lignes,
    required this.voitValeur,
    required this.onRavitailler,
  });

  final List<StockLine> lignes;
  final bool voitValeur;
  final void Function(StockLine)? onRavitailler;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const ecart = 14.0;
        final colonnes = math.max(1, ((c.maxWidth + ecart) / (270 + ecart)).floor());
        final largeur = (c.maxWidth - ecart * (colonnes - 1)) / colonnes;
        return Wrap(
          spacing: ecart,
          runSpacing: ecart,
          children: [
            for (final l in lignes)
              SizedBox(
                width: largeur,
                child: _CarteProduit(
                  ligne: l,
                  voitValeur: voitValeur,
                  onRavitailler: onRavitailler,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CarteProduit extends StatelessWidget {
  const _CarteProduit({
    required this.ligne,
    required this.voitValeur,
    required this.onRavitailler,
  });

  final StockLine ligne;
  final bool voitValeur;
  final void Function(StockLine)? onRavitailler;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final l = ligne;
    final etat = l.etat;
    final alerte = etat != _Etat.enStock;
    final seuil = l.minStock;

    // Les faits, en chiffres exacts ; l'unite est deja a cote de la
    // quantite.
    final (String, String) ecart = seuil == 0
        ? ('Écart', 'sans seuil')
        : l.quantity < seuil
        ? ('Il manque', '${seuil - l.quantity}')
        : ('Au-dessus', '+${l.quantity - seuil}');
    final faits = <(String, String, int)>[
      ('Seuil', seuil == 0 ? 'non fixé' : '$seuil', 2),
      (ecart.$1, ecart.$2, 2),
      if (voitValeur)
        ('Valeur', formatAmount(math.max(0, l.quantity) * l.purchasePrice), 3),
    ];
    final libelle = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 12,
      color: p.textSecondary,
    );
    final valeur = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 13.5,
      fontWeight: FontWeight.w700,
      color: p.text,
      fontFeatures: tabularFigures,
    );

    return Container(
      decoration: BoxDecoration(
        color: p.paper,
        borderRadius: BorderRadius.circular(AtriumRadii.lg),
        border: Border.all(color: p.border),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    Text(
                      l.reference,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: libelle,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _BadgeEtat(etat: etat),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 40,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${l.quantity}',
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.6,
                          color: p.text,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                      TextSpan(
                        text: '  ${l.unit}',
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 13,
                          color: p.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                ),
                const Spacer(),
                if (alerte && onRavitailler != null)
                  TextButton.icon(
                    onPressed: () => onRavitailler!(l),
                    icon: const Icon(PhosphorIconsLight.arrowsLeftRight, size: 16),
                    label: const Text('Ravitailler'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: p.border),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final (i, (titre, texte, place)) in faits.indexed) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(
                  flex: place,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(titre, maxLines: 1, overflow: TextOverflow.ellipsis, style: libelle),
                      const SizedBox(height: 2),
                      Text(texte, maxLines: 1, overflow: TextOverflow.ellipsis, style: valeur),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// --- La vue en tableau -------------------------------------------------------

/// Le choix entre tableau et cartes : deux segments, une pastille qui glisse
/// sous celui retenu. Sur telephone, les icones seules.
class _ChoixVue extends StatelessWidget {
  const _ChoixVue({
    required this.vue,
    required this.compact,
    required this.onChoisi,
  });

  final _Vue vue;
  final bool compact;
  final ValueChanged<_Vue> onChoisi;

  static const _segments = [
    (_Vue.liste, 'Liste', PhosphorIconsLight.list),
    (_Vue.cartes, 'Cartes', PhosphorIconsLight.squaresFour),
  ];

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final largeur = compact ? 46.0 : 96.0;
    final rayon = BorderRadius.circular(AtriumRadii.md - 2);
    final index = _segments.indexWhere((s) => s.$1 == vue);
    return Container(
      height: 44,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.paper,
        borderRadius: rayon,
        border: Border.all(color: p.border),
      ),
      child: SizedBox(
        width: largeur * _segments.length,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: AtriumMotion.of(context, AtriumMotion.base),
              curve: atriumSpring,
              left: largeur * index,
              top: 0,
              bottom: 0,
              width: largeur,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.selected,
                  borderRadius: BorderRadius.circular(AtriumRadii.sm),
                ),
              ),
            ),
            Row(
              children: [
                for (final (valeur, libelle, icone) in _segments)
                  SizedBox(
                    width: largeur,
                    child: Tooltip(
                      message: valeur == _Vue.liste
                          ? 'Afficher en tableau'
                          : 'Afficher en cartes',
                      child: Semantics(
                        button: true,
                        selected: valeur == vue,
                        label: libelle,
                        excludeSemantics: true,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(AtriumRadii.sm),
                          onTap: () => onChoisi(valeur),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  icone,
                                  size: 18,
                                  color: valeur == vue
                                      ? p.onSelected
                                      : p.textSecondary,
                                ),
                                if (!compact) ...[
                                  const SizedBox(width: 6),
                                  // Souple : une police plus large que
                                  // prevu ne fait pas deborder la case.
                                  Flexible(
                                    child: Text(
                                    libelle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: atriumFontFamily,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: valeur == vue
                                          ? p.onSelected
                                          : p.text,
                                    ),
                                  ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
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

/// Le bouton Ravitailler tient sur une ligne : sa colonne a une largeur
/// fixe, les autres se partagent le reste.
const _largeurAction = 136.0;

/// Les colonnes du tableau. Les chiffres s'alignent a droite, comme dans un
/// registre : les unites tombent sous les unites.
enum _ColStock {
  produit('Produit', 30),
  etat('État', 15),
  quantite('Quantité', 14, droite: true),
  seuil('Seuil', 10, droite: true),
  ecart('Écart au seuil', 14, droite: true),
  valeur('Valeur', 17, droite: true),
  action('', 0);

  const _ColStock(this.titre, this.flex, {this.droite = false});

  final String titre;
  final int flex;
  final bool droite;

  /// La colonne qui trie quand on touche son titre.
  _Tri? get tri => switch (this) {
    _ColStock.produit => _Tri.nom,
    _ColStock.etat => _Tri.urgence,
    _ColStock.quantite => _Tri.quantite,
    _ => null,
  };
}

/// Les produits en tableau : une ligne par produit, les memes chiffres
/// exacts que les cartes. Les colonnes accessoires tombent quand la largeur
/// manque ; le produit, son etat et sa quantite restent.
class _TableauProduits extends StatelessWidget {
  const _TableauProduits({
    super.key,
    required this.lignes,
    required this.voitValeur,
    required this.tri,
    required this.onTri,
    required this.onRavitailler,
  });

  final List<StockLine> lignes;
  final bool voitValeur;
  final _Tri tri;
  final ValueChanged<_Tri> onTri;
  final void Function(StockLine)? onRavitailler;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        // Sur telephone, l'etat passe sous le nom du produit : en colonne,
        // il ne tenait qu'en rapetissant.
        final etroit = w < 620;
        final colonnes = [
          _ColStock.produit,
          if (!etroit) _ColStock.etat,
          _ColStock.quantite,
          if (w >= 720) ...[_ColStock.seuil, _ColStock.ecart],
          if (voitValeur && w >= 900) _ColStock.valeur,
          if (onRavitailler != null && w >= 620) _ColStock.action,
        ];
        // Sur telephone, Ravitailler devient une icone en bout de ligne.
        final boutonSeul = onRavitailler != null && etroit;
        return Bezel(
          radius: 22,
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: p.surface,
                    border: Border(bottom: BorderSide(color: p.border)),
                  ),
                  child: Row(
                    children: [
                      for (final col in colonnes)
                        if (col == _ColStock.action)
                          const SizedBox(width: _largeurAction)
                        else
                          Expanded(
                            flex: col.flex,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: _TitreColonne(
                                colonne: col,
                                actif: col.tri != null && col.tri == tri,
                                onTri: onTri,
                              ),
                            ),
                          ),
                      if (boutonSeul) const SizedBox(width: 44),
                    ],
                  ),
                ),
                for (final (i, l) in lignes.indexed)
                  _LigneProduit(
                    ligne: l,
                    colonnes: colonnes,
                    filet: i < lignes.length - 1,
                    etroit: etroit,
                    boutonSeul: boutonSeul,
                    onRavitailler: onRavitailler,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TitreColonne extends StatelessWidget {
  const _TitreColonne({
    required this.colonne,
    required this.actif,
    required this.onTri,
  });

  final _ColStock colonne;
  final bool actif;
  final ValueChanged<_Tri> onTri;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final texte = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            colonne.titre,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: actif ? p.text : p.textSecondary,
            ),
          ),
        ),
        if (actif) ...[
          const SizedBox(width: 4),
          Icon(PhosphorIconsLight.caretDown, size: 13, color: p.accent),
        ],
      ],
    );
    final aligne = Align(
      alignment: colonne.droite ? Alignment.centerRight : Alignment.centerLeft,
      child: texte,
    );
    final tri = colonne.tri;
    if (tri == null) return aligne;
    return Semantics(
      button: true,
      selected: actif,
      label: 'Trier par ${tri.libelle.toLowerCase()}',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTri(tri),
          child: aligne,
        ),
      ),
    );
  }
}

class _LigneProduit extends StatelessWidget {
  const _LigneProduit({
    required this.ligne,
    required this.colonnes,
    required this.filet,
    required this.etroit,
    required this.boutonSeul,
    required this.onRavitailler,
  });

  final StockLine ligne;
  final List<_ColStock> colonnes;
  final bool filet;
  final bool etroit;
  final bool boutonSeul;
  final void Function(StockLine)? onRavitailler;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final l = ligne;
    final alerte = l.etat != _Etat.enStock;
    final chiffre = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
      color: p.text,
      fontFeatures: tabularFigures,
    );
    final discret = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: p.placeholder,
    );

    Widget cellule(_ColStock c) {
      switch (c) {
        case _ColStock.produit:
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                ),
              ),
              if (etroit) ...[
                const SizedBox(height: 6),
                _BadgeEtat(etat: l.etat),
              ] else if (l.reference.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  l.reference,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12.5,
                    color: p.textSecondary,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ],
            ],
          );
        case _ColStock.etat:
          return Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: _BadgeEtat(etat: l.etat),
            ),
          );
        case _ColStock.quantite:
          if (etroit) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${l.quantity}',
                  maxLines: 1,
                  style: chiffre.copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  l.unit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12.5,
                    color: p.textSecondary,
                  ),
                ),
              ],
            );
          }
          return Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${l.quantity}',
                  style: chiffre.copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text: ' ${l.unit}',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12.5,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
          );
        case _ColStock.seuil:
          return Text(
            l.minStock == 0 ? 'Non fixé' : '${l.minStock}',
            maxLines: 1,
            textAlign: TextAlign.right,
            style: l.minStock == 0 ? discret : chiffre,
          );
        case _ColStock.ecart:
          final seuil = l.minStock;
          if (seuil == 0) {
            return Text(
              'Sans seuil',
              maxLines: 1,
              textAlign: TextAlign.right,
              style: discret,
            );
          }
          return Text(
            l.quantity < seuil
                ? 'Il manque ${seuil - l.quantity}'
                : '+${l.quantity - seuil}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: l.quantity < seuil
                ? chiffre.copyWith(fontWeight: FontWeight.w700)
                : chiffre.copyWith(
                    color: p.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
          );
        case _ColStock.valeur:
          return Text(
            formatAmount(math.max(0, l.quantity) * l.purchasePrice),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: chiffre,
          );
        case _ColStock.action:
          if (!alerte) return const SizedBox.shrink();
          return Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => onRavitailler!(l),
              icon: const Icon(PhosphorIconsLight.arrowsLeftRight, size: 16),
              label: const Text('Ravitailler'),
            ),
          );
      }
    }

    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      decoration: BoxDecoration(
        border: filet ? Border(bottom: BorderSide(color: p.grid)) : null,
      ),
      child: Row(
        children: [
          for (final c in colonnes)
            if (c == _ColStock.action)
              SizedBox(width: _largeurAction, child: cellule(c))
            else
              Expanded(
                flex: c.flex,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: cellule(c),
                ),
              ),
          if (boutonSeul)
            SizedBox(
              width: 44,
              child: alerte
                  ? IconButton(
                      tooltip: 'Ravitailler',
                      onPressed: () => onRavitailler!(l),
                      icon: Icon(
                        PhosphorIconsLight.arrowsLeftRight,
                        size: 20,
                        color: p.accent,
                      ),
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}

// --- Les transferts a valider -------------------------------------------------

/// Les demandes de transfert en attente. Le controleur ou le comptable les
/// valide ou les refuse ; l'economat en ajuste la quantite, sans valider
/// (15 octobre).
class _AValider extends ConsumerWidget {
  const _AValider({required this.valide, required this.ajuste});

  final bool valide;
  final bool ajuste;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transferts = ref.watch(pendingTransfersProvider).value ?? const [];
    if (transferts.isEmpty) return const SizedBox.shrink();
    final p = AtriumPalette.current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Bezel(
        radius: 20,
        padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(PhosphorIconsLight.arrowsLeftRight, size: 20, color: p.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Transferts à valider',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                  ),
                  Tag('${transferts.length} en attente', color: p.warning),
                ],
              ),
            ),
            const SizedBox(height: 6),
            for (final t in transferts)
              _Transfert(transfert: t, valide: valide, ajuste: ajuste),
          ],
        ),
      ),
    );
  }
}

class _Transfert extends ConsumerWidget {
  const _Transfert({
    required this.transfert,
    required this.valide,
    required this.ajuste,
  });

  final PendingTransfer transfert;
  final bool valide;
  final bool ajuste;

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
                '${t.productLabel}, ${t.quantity} ${t.unit}',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AtriumColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.fromLabel,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13,
                      color: AtriumColors.textSecondary,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(
                      PhosphorIconsLight.arrowRight,
                      size: 14,
                      color: AtriumColors.textSecondary,
                    ),
                  ),
                  Text(
                    t.toLabel,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13,
                      color: AtriumColors.textSecondary,
                    ),
                  ),
                ],
              ),
              if (vide) ...[
                const SizedBox(height: 2),
                Text(
                  '${t.fromLabel} n’en a que ${t.availableAtSource}',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AtriumColors.warning,
                  ),
                ),
              ],
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ajuste) ...[
                OutlinedButton.icon(
                  onPressed: () => _ajuster(context, ref),
                  icon: const Icon(PhosphorIconsLight.pencilSimple, size: 18),
                  label: const Text('Ajuster'),
                ),
                if (valide) const SizedBox(width: 10),
              ],
              if (valide) ...[
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
            ],
          ),
        ],
      ),
    );
  }

  /// L'economat accorde moins (ou plus) que demande : le bar demande 10
  /// bieres, il n'en reste que 12, il en donne 8.
  Future<void> _ajuster(BuildContext context, WidgetRef ref) async {
    final t = transfert;
    final quantite = TextEditingController(text: '${t.quantity}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Ajuster la quantité'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${t.toLabel} demande ${t.quantity} ${t.unit} de '
                '${t.productLabel} à ${t.fromLabel}.',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: quantite,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Quantité accordée',
                  suffixText: t.unit,
                  helperText: '${t.fromLabel} en a ${t.availableAtSource}',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Le contrôleur ou le comptable validera ensuite.',
                style: TextStyle(
                  fontSize: 13,
                  color: AtriumColors.textSecondary,
                ),
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
            child: const Text('Ajuster'),
          ),
        ],
      ),
    );
    final q = int.tryParse(quantite.text.trim()) ?? 0;
    quantite.dispose();
    if (ok != true || !context.mounted) return;
    await _faire(context, () async {
      await ref.read(stockRepositoryProvider).ajuster(t.id, quantite: q);
      return 'Demande ajustée : ${t.toLabel} recevra $q ${t.unit} une fois '
          'le transfert validé.';
    });
  }

  Future<void> _decider(
    BuildContext context,
    WidgetRef ref, {
    required bool approuve,
  }) async {
    final t = transfert;
    final note = await demanderMotif(
      context,
      titre: approuve ? 'Valider le transfert' : 'Refuser le transfert',
      libelleRenoncer: 'Retour',
      libelleConfirmer: approuve ? 'Valider' : 'Refuser',
      contenu: Text(
        '${t.quantity} ${t.unit} de ${t.productLabel}, de '
        '${t.fromLabel} vers ${t.toLabel}.'
        '${approuve && t.availableAtSource < t.quantity ? '\n\n${t.fromLabel} n’en a que ${t.availableAtSource} : son stock passera sous zéro.' : ''}',
        style: const TextStyle(fontSize: 16),
      ),
    );
    if (note == null || !context.mounted) return;
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
    this.perte = false,
  });

  /// Une sortie : perdue (casse, perime) plutot qu'utilisee.
  final bool perte;
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
    this.ravitaillement = false,
    this.produitId,
    this.sortie = false,
  });

  /// Une sortie sans vente : utilisation ou perte, motif obligatoire.
  final bool sortie;
  final String titre;

  /// Le produit deja choisi : on ravitaille depuis sa ligne.
  final String? produitId;

  /// Le point de vente se ravitaille : la liste est celle des magasins d'ou
  /// la marchandise peut venir, et non de ceux ou elle peut aller.
  final bool ravitaillement;

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
  bool _perte = false;

  @override
  void dispose() {
    _quantite.dispose();
    _prix.dispose();
    _motif.dispose();
    super.dispose();
  }

  int get _q => int.tryParse(_quantite.text.trim()) ?? 0;

  bool get _pret =>
      _produit != null &&
      _q > 0 &&
      (widget.sortie
          ? _motif.text.trim().isNotEmpty
          : (widget.entree || _destination != null));

  bool _initial = false;

  @override
  Widget build(BuildContext context) {
    final produits = ref.watch(stockProductsProvider).value ?? const [];
    // Le produit de la ligne, une fois la liste arrivee ; ensuite, le choix
    // de l'agent.
    if (!_initial && widget.produitId != null && produits.isNotEmpty) {
      _initial = true;
      _produit = produits.where((p) => p.id == widget.produitId).firstOrNull;
      if (widget.entree && _produit != null && _produit!.purchasePrice > 0) {
        _prix.text = '${_produit!.purchasePrice}';
      }
    }
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
            if (widget.sortie) ...[
              const SizedBox(height: 14),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Utilisation')),
                  ButtonSegment(value: true, label: Text('Perte / casse')),
                ],
                selected: {_perte},
                onSelectionChanged: (v) => setState(() => _perte = v.first),
              ),
              const SizedBox(height: 6),
              Text(
                _perte
                    ? 'Cassé, périmé, disparu : compté en perte.'
                    : 'Utilisé sans être vendu : cuisine, chambres, spa.',
                style: TextStyle(
                  fontSize: 13,
                  color: AtriumColors.textSecondary,
                ),
              ),
            ],
            if (!widget.entree && !widget.sortie) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<StockPlace>(
                initialValue: _destination,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: widget.ravitaillement ? 'Depuis' : 'Vers',
                ),
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
            // Ce qu'a le magasin d'ou part la marchandise : le choisi pour
            // un ravitaillement, celui de l'onglet pour un transfert.
            if (!widget.entree &&
                !widget.sortie &&
                _produit != null &&
                (widget.ravitaillement ? _destination : widget.depart) != null)
              _DisponibleAuDepart(
                magasin: (widget.ravitaillement ? _destination : widget.depart)!,
                produitId: _produit!.id,
                demande: _q,
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _motif,
              maxLength: 255,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: widget.entree
                    ? 'Fournisseur, bon de livraison (facultatif)'
                    : widget.sortie
                    ? 'Motif'
                    : 'Motif (facultatif)',
                hintText: widget.sortie
                    ? (_perte ? 'Bouteille cassée au service' : 'Chambres du 2e étage')
                    : null,
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
                    perte: _perte,
                  ),
                ),
          child: Text(
            widget.sortie
                ? 'Enregistrer la sortie'
                : widget.entree
                ? 'Enregistrer l’entrée'
                : widget.ravitaillement
                ? 'Demander le ravitaillement'
                : 'Demander le transfert',
          ),
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
