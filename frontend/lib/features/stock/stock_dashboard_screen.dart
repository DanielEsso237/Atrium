/// Le tableau de bord des stocks (demande du 18 octobre).
///
/// Un clic sur « Stocks » ouvre cet ecran ; la fleche du menu deplie ses
/// vues : État des stocks (la liste produit par produit), Inventaire,
/// Historique des stocks.
///
/// Ce qu'il faut voir en arrivant : ce que vaut le stock, ce qui manque ou
/// passe sous zero -- magasin par magasin --, ce qui attend une validation
/// ou un comptage, et ce qui vient d'entrer ou de sortir. La valeur ne
/// s'affiche qu'a qui la lit sur l'ecran Stocks (`stock.manage`,
/// `accounting.read`) ; les autres voient les quantites.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/choix_en_menu.dart';
import '../../core/widgets/historique.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../core/widgets/tableau_de_bord.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/stock_tableau_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/stock_repository.dart';
import '../auth/session.dart';
import '../dashboard/dashboard_charts.dart' show Legende;
import '../reports/report_charts.dart';
import 'stock_presentation.dart';

/// Les magasins regardes : leurs ids joints par une virgule, une cle
/// comparable.
List<String> _ids(String cle) => cle.isEmpty ? const [] : cle.split(',');

final _etatsProvider = StreamProvider.family<List<EtatMagasin>, String>(
  (ref, cle) => ref.watch(databaseProvider).watchEtatsMagasins(_ids(cle)),
);

final _alertesProvider = StreamProvider.family<List<AlerteStock>, String>(
  (ref, cle) =>
      ref.watch(databaseProvider).watchAlertesStock(_ids(cle), limite: 8),
);

final _derniersProvider = StreamProvider.family<List<MouvementStock>, String>(
  (ref, cle) =>
      ref.watch(databaseProvider).watchMouvementsStock(_ids(cle), limite: 6),
);

final _inventairesProvider =
    StreamProvider.family<List<InventaireStock>, String>(
      (ref, cle) =>
          ref.watch(databaseProvider).watchInventairesStock(_ids(cle)),
    );

/// Les quatorze derniers jours : entrees, puis sorties.
final _fluxProvider = StreamProvider.family<(List<int>, List<int>), String>((
  ref,
  cle,
) {
  final aujourdhui = DateTime.now();
  return ref
      .watch(databaseProvider)
      .watchFluxStock(
        _ids(cle),
        du: aujourdhui.subtract(const Duration(days: 13)),
        au: aujourdhui,
      );
});

/// Les couleurs des etats : celles de l'ecran Stocks. Rupture et negatif y
/// partagent le rouge ; ici, cote a cote dans un anneau, la rupture prend
/// le pole chaud de la charte pour s'en distinguer -- chaque part dit aussi
/// son nom et son nombre.
Color _couleurEnStock(AtriumPalette p) => p.success;
Color _couleurBas(AtriumPalette p) => p.warning;
const _couleurRupture = AtriumChartColors.negatif;
Color _couleurNegatif(AtriumPalette p) => p.error;

class StockDashboardScreen extends ConsumerStatefulWidget {
  const StockDashboardScreen({super.key});

  @override
  ConsumerState<StockDashboardScreen> createState() =>
      _StockDashboardScreenState();
}

class _StockDashboardScreenState extends ConsumerState<StockDashboardScreen> {
  /// `null` : tous les magasins de l'agent.
  String? _magasin;

  @override
  Widget build(BuildContext context) {
    const titre = 'Stocks';
    final session = ref.watch(sessionProvider);
    final acces = session.acces;
    final magasins = ref.watch(stockPlacesProvider(session.agent?.id)).value;
    if (magasins == null) {
      return const ModuleScaffold(
        title: titre,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (magasins.isEmpty) {
      return const ModuleScaffold(
        title: titre,
        body: EmptyState(
          icon: PhosphorIconsLight.archive,
          title: 'Aucun magasin',
          message:
              'Les magasins arrivent du serveur : lancez une synchronisation.',
        ),
      );
    }
    final choisi = magasins.where((m) => m.id == _magasin).firstOrNull;
    final regardes = choisi == null ? magasins : [choisi];
    final cle = [for (final m in regardes) m.id].join(',');
    final voitValeur =
        acces.peut('stock.manage') || acces.peut('accounting.read');
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    final etats = ref.watch(_etatsProvider(cle)).value ?? const <EtatMagasin>[];
    final noms = {for (final m in regardes) m.label};
    final transferts = [
      for (final t
          in ref.watch(pendingTransfersProvider).value ??
              const <PendingTransfer>[])
        if (noms.contains(t.fromLabel) || noms.contains(t.toLabel)) t,
    ];
    final inventaires = [
      for (final i
          in ref.watch(_inventairesProvider(cle)).value ??
              const <InventaireStock>[])
        if (i.ouvert) i,
    ];

    return ModuleScaffold(
      title: titre,
      subtitle: choisi != null
          ? choisi.label
          : magasins.length == 1
          ? magasins.single.label
          : '${magasins.length} magasins, l’économat d’abord',
      action: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          PillButton(
            label: 'Historique',
            icon: PhosphorIconsLight.clockCounterClockwise,
            tone: PillTone.quiet,
            onPressed: () => context.go('/stocks/historique'),
          ),
          PillButton(
            label: 'État des stocks',
            icon: PhosphorIconsLight.list,
            tone: PillTone.accent,
            onPressed: () => context.go('/stocks/etat'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (magasins.length > 1)
            Padding(
              padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ChoixEnMenu<String?>(
                  choisi: choisi?.id,
                  onChoisi: (id) => setState(() => _magasin = id),
                  compte: '${magasins.length} magasins',
                  options: [
                    const OptionMenu(
                      null,
                      'Tous les magasins',
                      icone: PhosphorIconsLight.squaresFour,
                      genre: 'Magasins',
                    ),
                    for (final m in magasins)
                      OptionMenu(
                        m.id,
                        m.label,
                        icone: m.isCentral
                            ? PhosphorIconsLight.archive
                            : PhosphorIconsLight.storefront,
                        genre: m.isCentral ? 'Magasin central' : 'Point de vente',
                      ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: TableauAnime(
              cle: cle,
              builder: (context, trace, barres) => ListView(
                padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
                children: [
                  _Bandeau(
                    etats: etats,
                    voitValeur: voitValeur,
                    transferts: transferts.length,
                    inventaires: inventaires.length,
                  ),
                  const SizedBox(height: 16),
                  DeuxColonnes(
                    flexGauche: 3,
                    flexDroite: 2,
                    gauche: _Sante(
                      etats: etats,
                      onChoisir: magasins.length > 1 && choisi == null
                          ? (id) => setState(() => _magasin = id)
                          : null,
                    ),
                    droite: _Repartition(etats: etats, progres: barres),
                  ),
                  const SizedBox(height: 16),
                  DeuxColonnes(
                    gauche: _ASurveiller(cle: cle),
                    droite: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Transferts(transferts: transferts),
                        const SizedBox(height: 16),
                        _Inventaires(inventaires: inventaires),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  DeuxColonnes(
                    flexGauche: 3,
                    flexDroite: 2,
                    gauche: _Flux(cle: cle, progres: barres),
                    droite: voitValeur
                        ? _ValeurParMagasin(etats: etats, progres: barres)
                        : _AlertesParMagasin(etats: etats, progres: barres),
                  ),
                  const SizedBox(height: 16),
                  _Derniers(cle: cle, regardes: {for (final m in regardes) m.id}),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Le bandeau -----------------------------------------------------------------

class _Bandeau extends StatelessWidget {
  const _Bandeau({
    required this.etats,
    required this.voitValeur,
    required this.transferts,
    required this.inventaires,
  });

  final List<EtatMagasin> etats;
  final bool voitValeur;
  final int transferts;
  final int inventaires;

  @override
  Widget build(BuildContext context) {
    int somme(int Function(EtatMagasin) f) => etats.fold(0, (s, e) => s + f(e));
    final produits = somme((e) => e.produits);
    final enStock = somme((e) => e.enStock);
    final alertes = somme((e) => e.enAlerte);
    final part = produits == 0 ? 0 : (enStock * 100 / produits).round();
    return BandeauChiffres(
      libelle: voitValeur ? 'Valeur du stock' : 'Produits à surveiller',
      valeur: voitValeur ? formatAmount(somme((e) => e.valeur)) : '$alertes',
      mesures: [
        Mesure(
          'Produits suivis',
          '$produits',
          aide: '$part % en stock',
        ),
        Mesure(
          'Stock bas',
          '${somme((e) => e.bas)}',
          aide: 'Sous leur seuil',
          alerte: somme((e) => e.bas) > 0,
        ),
        Mesure(
          'Rupture',
          '${somme((e) => e.rupture)}',
          aide: 'Plus rien en magasin',
          alerte: somme((e) => e.rupture) > 0,
        ),
        Mesure(
          'Négatif',
          '${somme((e) => e.negatif)}',
          aide: 'Vendu avant d’être entré',
          alerte: somme((e) => e.negatif) > 0,
        ),
        Mesure(
          'Transferts à valider',
          '$transferts',
          aide: 'Par le contrôleur ou le comptable',
          onTap: transferts == 0 ? null : () => context.go('/stocks/etat'),
        ),
        Mesure(
          'Inventaires en cours',
          '$inventaires',
          onTap: inventaires == 0 ? null : () => context.go('/inventaire'),
        ),
      ],
    );
  }
}

// --- La sante des magasins ------------------------------------------------------------

/// Une barre par magasin, decoupee par etat : on voit d'un coup d'oeil quel
/// magasin manque de quoi. Toucher un magasin ne regarde que lui.
class _Sante extends StatelessWidget {
  const _Sante({required this.etats, this.onChoisir});

  final List<EtatMagasin> etats;
  final ValueChanged<String>? onChoisir;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return CarteSection(
      titre: 'Santé des magasins',
      icone: PhosphorIconsLight.pulse,
      description: onChoisir == null
          ? 'Chaque produit suivi, selon son état.'
          : 'Chaque produit suivi, selon son état. Touchez un magasin '
                'pour ne regarder que lui.',
      child: etats.isEmpty
          ? const SectionVide('Aucun produit suivi.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    Legende(couleur: _couleurEnStock(p), libelle: 'En stock'),
                    Legende(couleur: _couleurBas(p), libelle: 'Stock bas'),
                    const Legende(couleur: _couleurRupture, libelle: 'Rupture'),
                    Legende(couleur: _couleurNegatif(p), libelle: 'Négatif'),
                  ],
                ),
                const SizedBox(height: 12),
                for (final e in etats)
                  HoverRow(
                    onTap: onChoisir == null ? null : () => onChoisir!(e.id),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 9,
                    ),
                    child: Semantics(
                      label:
                          '${e.libelle} : ${e.enStock} en stock, ${e.bas} bas, '
                          '${e.rupture} en rupture, ${e.negatif} négatifs',
                      child: ExcludeSemantics(child: _BarreSante(etat: e)),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _BarreSante extends StatelessWidget {
  const _BarreSante({required this.etat});

  final EtatMagasin etat;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final e = etat;
    final parts = [
      (e.enStock, _couleurEnStock(p)),
      (e.bas, _couleurBas(p)),
      (e.rupture, _couleurRupture),
      (e.negatif, _couleurNegatif(p)),
    ].where((x) => x.$1 > 0).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                e.libelle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: p.text,
                ),
              ),
            ),
            Text(
              e.enAlerte == 0
                  ? '${e.produits} produits, tout est en stock'
                  : '${e.enAlerte} sur ${e.produits} à surveiller',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 12.5,
                color: e.enAlerte == 0 ? p.textSecondary : p.text,
                fontWeight: e.enAlerte == 0 ? null : FontWeight.w600,
                fontFeatures: tabularFigures,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Les segments, separes par un filet de surface de 2 points.
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 10,
            // Etirees en hauteur : un aplat sans enfant n'en prend pas.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, (n, couleur)) in parts.indexed) ...[
                  if (i > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: n,
                    child: ColoredBox(color: couleur),
                  ),
                ],
                if (parts.isEmpty)
                  Expanded(child: ColoredBox(color: p.border)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// --- La repartition -------------------------------------------------------------------

class _Repartition extends StatelessWidget {
  const _Repartition({required this.etats, required this.progres});

  final List<EtatMagasin> etats;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    int somme(int Function(EtatMagasin) f) => etats.fold(0, (s, e) => s + f(e));
    return CarteSection(
      titre: 'État des produits',
      icone: PhosphorIconsLight.chartDonut,
      child: AnneauRapport(
        progres: progres,
        libelleTotal: 'produits suivis',
        description: 'Produits suivis par état',
        ecrire: (n) => '$n',
        vide: 'Aucun produit suivi.',
        parts: [
          PartAnneau('En stock', somme((e) => e.enStock), _couleurEnStock(p)),
          PartAnneau('Stock bas', somme((e) => e.bas), _couleurBas(p)),
          PartAnneau('Rupture', somme((e) => e.rupture), _couleurRupture),
          PartAnneau('Négatif', somme((e) => e.negatif), _couleurNegatif(p)),
        ],
      ),
    );
  }
}

// --- A surveiller -----------------------------------------------------------------------

class _ASurveiller extends ConsumerWidget {
  const _ASurveiller({required this.cle});

  final String cle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final alertes =
        ref.watch(_alertesProvider(cle)).value ?? const <AlerteStock>[];
    return CarteSection(
      titre: 'À surveiller',
      icone: PhosphorIconsLight.warningCircle,
      description: 'Le plus urgent d’abord : négatif, rupture, puis le plus '
          'loin de son seuil.',
      action: LienSection(
        libelle: 'État des stocks',
        icone: PhosphorIconsLight.list,
        onPressed: () => context.go('/stocks/etat'),
      ),
      child: alertes.isEmpty
          ? const SectionVide('Tout est au-dessus de son seuil.')
          : Column(
              children: [
                for (final (i, a) in alertes.indexed) ...[
                  if (i > 0) Divider(height: 1, color: p.border),
                  _LigneAlerte(alerte: a),
                ],
              ],
            ),
    );
  }
}

class _LigneAlerte extends StatelessWidget {
  const _LigneAlerte({required this.alerte});

  final AlerteStock alerte;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final a = alerte;
    final (etat, couleur) = libelleEtatProduit(a.etat);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.produit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                Text(
                  a.seuil > 0
                      ? '${a.magasin}, seuil ${a.seuil} ${a.unite}'
                      : a.magasin,
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
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${a.quantite} ${a.unite}',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: a.quantite < 0 ? p.error : p.text,
              fontFeatures: tabularFigures,
            ),
          ),
          const SizedBox(width: 10),
          Tag(etat, color: couleur),
        ],
      ),
    );
  }
}

// --- Les transferts et les inventaires ---------------------------------------------------

class _Transferts extends StatelessWidget {
  const _Transferts({required this.transferts});

  final List<PendingTransfer> transferts;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final doux = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 12.5,
      color: p.textSecondary,
      fontFeatures: tabularFigures,
    );
    return CarteSection(
      titre: 'Transferts à valider',
      icone: PhosphorIconsLight.arrowsLeftRight,
      action: transferts.isEmpty
          ? null
          : LienSection(
              libelle: 'Valider',
              icone: PhosphorIconsLight.checks,
              onPressed: () => context.go('/stocks/etat'),
            ),
      child: transferts.isEmpty
          ? const SectionVide('Aucun transfert n’attend.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final t in transferts.take(5))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.productLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: atriumFontFamily,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                  color: p.text,
                                ),
                              ),
                              Text(
                                'De ${t.fromLabel} vers ${t.toLabel}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: doux,
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '${t.quantity} ${t.unit}',
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: t.quantity > t.availableAtSource
                                ? p.warning
                                : p.text,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (transferts.length > 5)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Et ${transferts.length - 5} de plus.',
                      style: doux,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Inventaires extends StatelessWidget {
  const _Inventaires({required this.inventaires});

  final List<InventaireStock> inventaires;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return CarteSection(
      titre: 'Inventaires en cours',
      icone: PhosphorIconsLight.checks,
      action: inventaires.isEmpty
          ? null
          : LienSection(
              libelle: 'Compter',
              icone: PhosphorIconsLight.arrowUpRight,
              onPressed: () => context.go('/inventaire'),
            ),
      child: inventaires.isEmpty
          ? const SectionVide('Aucun inventaire ouvert.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final i in inventaires)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                i.magasin,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: atriumFontFamily,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                  color: p.text,
                                ),
                              ),
                            ),
                            Text(
                              '${i.comptees} sur ${i.lignes} comptés',
                              style: TextStyle(
                                fontFamily: atriumFontFamily,
                                fontSize: 12.5,
                                color: p.textSecondary,
                                fontFeatures: tabularFigures,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: i.lignes == 0 ? 0 : i.comptees / i.lignes,
                            minHeight: 6,
                            color: p.accent,
                            backgroundColor: p.border,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

// --- Les flux ------------------------------------------------------------------------------

class _Flux extends ConsumerWidget {
  const _Flux({required this.cle, required this.progres});

  final String cle;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (entrees, sorties) =
        ref.watch(_fluxProvider(cle)).value ?? (const <int>[], const <int>[]);
    final debut = DateTime.now().subtract(const Duration(days: 13));
    DateTime jour(int i) => DateTime(debut.year, debut.month, debut.day + i);
    final rien =
        entrees.every((v) => v == 0) && sorties.every((v) => v == 0);
    return CarteSection(
      titre: 'Entrées et sorties',
      icone: PhosphorIconsLight.chartBar,
      description: 'Les quatorze derniers jours, en quantités, tels que '
          'cette tablette les a enregistrés.',
      child: rien
          ? const SectionVide('Aucun mouvement sur ces quatorze jours.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 16,
                  children: [
                    Legende(
                      couleur: AtriumChartColors.parts[0],
                      libelle: 'Entrées',
                    ),
                    Legende(
                      couleur: AtriumChartColors.parts[1],
                      libelle: 'Sorties',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 200,
                  child: ColonnesRapport(
                    progres: progres,
                    series: [
                      SerieCourbe('Entrées', entrees, AtriumChartColors.parts[0]),
                      SerieCourbe('Sorties', sorties, AtriumChartColors.parts[1]),
                    ],
                    lire: (i) =>
                        '${formatWeekdayShort(jour(i))} ${formatDayMonth(jour(i))} : '
                        '${entrees[i]} entrés, ${sorties[i]} sortis',
                    description: 'Entrées et sorties jour par jour',
                    etiquetteDebut: formatDayMonth(jour(0)),
                    etiquetteFin: formatDayMonth(jour(entrees.length - 1)),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ValeurParMagasin extends StatelessWidget {
  const _ValeurParMagasin({required this.etats, required this.progres});

  final List<EtatMagasin> etats;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final total = etats.fold(0, (s, e) => s + e.valeur);
    final tries = [...etats]..sort((a, b) => b.valeur.compareTo(a.valeur));
    return CarteSection(
      titre: 'Valeur par magasin',
      icone: PhosphorIconsLight.coins,
      description: 'Au prix d’achat.',
      child: BarresParts(
        couleur: AtriumChartColors.current,
        progres: progres,
        vide: 'Aucun stock valorisé.',
        parts: [
          for (final e in tries.take(8))
            if (e.valeur > 0)
              BarrePart(
                e.libelle,
                e.valeur,
                formatAmount(e.valeur),
                detail: total == 0 ? null : '${(e.valeur * 100 / total).round()} %',
              ),
        ],
      ),
    );
  }
}

class _AlertesParMagasin extends StatelessWidget {
  const _AlertesParMagasin({required this.etats, required this.progres});

  final List<EtatMagasin> etats;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final tries = [...etats]..sort((a, b) => b.enAlerte.compareTo(a.enAlerte));
    return CarteSection(
      titre: 'Alertes par magasin',
      icone: PhosphorIconsLight.warningCircle,
      child: BarresParts(
        couleur: AtriumChartColors.negatif,
        progres: progres,
        vide: 'Aucune alerte.',
        parts: [
          for (final e in tries.take(8))
            if (e.enAlerte > 0)
              BarrePart(
                e.libelle,
                e.enAlerte,
                '${e.enAlerte}',
                detail: 'sur ${e.produits}',
              ),
        ],
      ),
    );
  }
}

// --- Les derniers mouvements ------------------------------------------------------------------

class _Derniers extends ConsumerWidget {
  const _Derniers({required this.cle, required this.regardes});

  final String cle;
  final Set<String> regardes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mouvements =
        ref.watch(_derniersProvider(cle)).value ?? const <MouvementStock>[];
    return CarteSection(
      titre: 'Derniers mouvements',
      icone: PhosphorIconsLight.clockCounterClockwise,
      action: LienSection(
        libelle: 'Tout l’historique',
        icone: PhosphorIconsLight.clockCounterClockwise,
        onPressed: () => context.go('/stocks/historique'),
      ),
      child: mouvements.isEmpty
          ? const SectionVide('Aucun mouvement enregistré sur cette tablette.')
          : Column(
              children: [
                for (final m in mouvements)
                  LigneHistorique(
                    entree: entreeDeMouvement(m, regardes: regardes),
                  ),
              ],
            ),
    );
  }
}
