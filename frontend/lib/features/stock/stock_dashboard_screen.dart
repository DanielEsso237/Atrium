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
import '../../data/local/enums.dart';
import '../../data/local/queries/stock_tableau_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/stock_repository.dart';
import '../auth/session.dart';
import '../dashboard/dashboard_charts.dart' show Legende;
import '../reports/report_charts.dart';
import 'stock_charts.dart';
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

/// Les mouvements des quatorze derniers jours, pour l'anneau par genre.
final _mouvements14Provider =
    StreamProvider.family<List<MouvementStock>, String>((ref, cle) {
      final j = DateTime.now().subtract(const Duration(days: 13));
      return ref
          .watch(databaseProvider)
          .watchMouvementsStock(
            _ids(cle),
            depuis: DateTime(j.year, j.month, j.day),
          );
    });

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
                    gauche: _EtatParMagasin(etats: etats, progres: barres),
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
                    droite: voitValeur && etats.length > 1
                        ? _ValeurParMagasin(etats: etats, progres: barres)
                        : _ParGenre(cle: cle, progres: barres),
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

// --- L'etat par magasin ----------------------------------------------------------------

/// Une colonne par magasin, empilee par etat : on voit d'un coup d'oeil quel
/// magasin manque de quoi, et le nombre exact de produits. Un seul magasin
/// regarde : une colonne par etat.
class _EtatParMagasin extends StatelessWidget {
  const _EtatParMagasin({required this.etats, required this.progres});

  final List<EtatMagasin> etats;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final libelles = ['En stock', 'Stock bas', 'Rupture', 'Négatif'];
    final couleurs = [
      _couleurEnStock(p),
      _couleurBas(p),
      _couleurRupture,
      _couleurNegatif(p),
    ];
    List<int> valeurs(EtatMagasin e) => [e.enStock, e.bas, e.rupture, e.negatif];
    int somme(int k) => etats.fold(0, (s, e) => s + valeurs(e)[k]);

    final unSeul = etats.length == 1;
    // Un magasin : quatre colonnes, une par etat ; sinon une par magasin.
    final categories = unSeul ? libelles : [for (final e in etats) e.libelle];
    final series = [
      for (var k = 0; k < 4; k++)
        SerieEmpilee(libelles[k], couleurs[k], [
          if (unSeul)
            for (var c = 0; c < 4; c++) c == k ? valeurs(etats.single)[k] : 0
          else
            for (final e in etats) valeurs(e)[k],
        ]),
    ];
    return CarteSection(
      titre: unSeul ? 'Produits par état' : 'État des stocks par magasin',
      icone: PhosphorIconsLight.chartBar,
      description: unSeul
          ? 'Chaque produit suivi, selon son état.'
          : 'Chaque produit suivi, magasin par magasin, selon son état.',
      child: etats.isEmpty
          ? const SectionVide('Aucun produit suivi.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!unSeul) ...[
                  Wrap(
                    spacing: 16,
                    runSpacing: 6,
                    children: [
                      for (var k = 0; k < 4; k++)
                        Legende(
                          couleur: couleurs[k],
                          libelle: '${libelles[k]} : ${somme(k)}',
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                ColonnesParCategorie(
                  categories: categories,
                  series: series,
                  progres: progres,
                  ecrire: (n) => '$n',
                  description: 'Produits suivis par état',
                  lire: (i) {
                    if (unSeul) {
                      return '${libelles[i]} : ${valeurs(etats.single)[i]} '
                          'produit${valeurs(etats.single)[i] > 1 ? 's' : ''}';
                    }
                    final e = etats[i];
                    return '${e.libelle} : ${e.produits} produits, '
                        '${e.enStock} en stock, ${e.bas} bas, '
                        '${e.rupture} en rupture, ${e.negatif} négatif'
                        '${e.negatif > 1 ? 's' : ''}';
                  },
                ),
              ],
            ),
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
                              '${i.comptees} / ${i.lignes} comptés',
                              style: TextStyle(
                                fontFamily: atriumFontFamily,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: p.text,
                                fontFeatures: tabularFigures,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          i.ecarts == 0
                              ? i.libelle
                              : '${i.libelle}, ${i.ecarts} écart'
                                    '${i.ecarts > 1 ? 's' : ''} déjà relevé'
                                    '${i.ecarts > 1 ? 's' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 12.5,
                            color: p.textSecondary,
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
    // Du plus riche au plus pauvre : le classement est la lecture.
    final tries = [
      for (final e in [...etats]..sort((a, b) => b.valeur.compareTo(a.valeur)))
        if (e.valeur > 0) e,
    ];
    return CarteSection(
      titre: 'Valeur par magasin',
      icone: PhosphorIconsLight.coins,
      description: 'Au prix d’achat, du plus garni au moins garni.',
      child: tries.isEmpty
          ? const SectionVide('Aucun stock valorisé.')
          : ColonnesParCategorie(
              categories: [for (final e in tries) e.libelle],
              series: [
                SerieEmpilee('Valeur', AtriumChartColors.current, [
                  for (final e in tries) e.valeur,
                ]),
              ],
              progres: progres,
              ecrire: montantCourt,
              description: 'Valeur du stock par magasin',
              lire: (i) =>
                  '${tries[i].libelle} : ${formatAmount(tries[i].valeur)}, '
                  '${(tries[i].valeur * 100 / total).round()} % du stock',
            ),
    );
  }
}

/// Ce qui a bouge ces quatorze jours, par genre de mouvement : la part des
/// entrees, des sorties, des transferts et des pertes.
class _ParGenre extends ConsumerWidget {
  const _ParGenre({required this.cle, required this.progres});

  final String cle;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mouvements =
        ref.watch(_mouvements14Provider(cle)).value ?? const <MouvementStock>[];
    int nombre(Set<StockMovementType> t) =>
        mouvements.where((m) => t.contains(m.type)).length;
    return CarteSection(
      titre: 'Mouvements par genre',
      icone: PhosphorIconsLight.chartDonut,
      description: 'Les quatorze derniers jours, sur cette tablette.',
      child: AnneauRapport(
        progres: progres,
        libelleTotal: 'mouvements',
        description: 'Mouvements de stock par genre',
        vide: 'Aucun mouvement sur ces quatorze jours.',
        ecrire: (n) => '$n',
        parts: [
          PartAnneau(
            'Entrées',
            nombre({StockMovementType.IN, StockMovementType.RETURN}),
            AtriumChartColors.parts[0],
          ),
          PartAnneau(
            'Sorties',
            nombre({StockMovementType.OUT}),
            AtriumChartColors.parts[1],
          ),
          PartAnneau(
            'Transferts',
            nombre({StockMovementType.TRANSFER}),
            AtriumChartColors.parts[2],
          ),
          PartAnneau(
            'Pertes et ajustements',
            nombre({StockMovementType.LOSS, StockMovementType.ADJUSTMENT}),
            AtriumChartColors.parts[3],
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
