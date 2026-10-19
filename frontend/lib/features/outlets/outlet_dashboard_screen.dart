/// Le tableau de bord des points de vente et des services.
///
/// Un seul ecran pour tous, parametre par le perimetre de l'agent : la
/// direction et la reception voient tout l'hotel, avec un filtre ; l'agent du
/// bar ne voit que le bar. Un point de vente cree demain y apparait de
/// lui-meme, sans une ligne de code.
///
/// L'argent encaisse et l'attendu des tiroirs s'affichent, tiroir ouvert ou
/// non (decision du 15 octobre, qui remplace le comptage a l'aveugle du 11).
///
/// Refait le 18 octobre avec les pieces communes des tableaux de bord : la
/// recette en grand, avec sa courbe des quatorze derniers jours et son ecart
/// a la periode d'avant ; puis la recette jour par jour, la facon dont les
/// clients paient, les heures de pointe, les meilleures ventes, les
/// dernieres ventes, les tiroirs et le stock. L'historique complet est a un
/// clic (`/ventes/historique`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
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
import '../../data/local/queries/historique_pdv_queries.dart'
    show EtatVentePdv;
import '../../data/local/queries/outlet_dashboard_queries.dart';
import '../../data/local/queries/ventes_historique_queries.dart';
import '../../data/repositories/order_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../reports/report_charts.dart';

/// Ce que l'agent a choisi de regarder.
class _Choix {
  const _Choix({this.genre, this.pointDeVente, this.periode = PeriodePdv.jour});

  /// `null` : le premier genre que l'agent voit.
  final OutletKind? genre;

  /// `null` : tous les points de vente du genre.
  final String? pointDeVente;
  final PeriodePdv periode;
}

class _ChoixNotifier extends Notifier<_Choix> {
  @override
  _Choix build() => const _Choix();

  void genre(OutletKind g) => state = _Choix(genre: g, periode: state.periode);

  void pointDeVente(String? id) => state = _Choix(
    genre: state.genre,
    pointDeVente: id,
    periode: state.periode,
  );

  void periode(PeriodePdv p) => state = _Choix(
    genre: state.genre,
    pointDeVente: state.pointDeVente,
    periode: p,
  );
}

final _choixProvider = NotifierProvider<_ChoixNotifier, _Choix>(
  _ChoixNotifier.new,
);

const _titre = 'Ventes';

/// La recette de chaque jour : des points de vente (leurs ids joints par une
/// virgule, une cle comparable), du premier au dernier jour.
final _recetteParJourProvider =
    StreamProvider.family<List<int>, (String, DateTime, DateTime)>(
      (ref, cle) => ref
          .watch(databaseProvider)
          .watchRecetteParJour(
            pointsDeVente: cle.$1.isEmpty ? const [] : cle.$1.split(','),
            du: cle.$2,
            au: cle.$3,
          ),
    );

/// Les dernieres ventes du tableau de bord.
final _dernieresVentesProvider =
    StreamProvider.family<List<VenteHistorique>, String>(
      (ref, ids) => ref
          .watch(databaseProvider)
          .watchHistoriqueVentes(
            pointsDeVente: ids.isEmpty ? const [] : ids.split(','),
            limite: 6,
          ),
    );

/// La couleur et le mot de l'etat d'une vente : les memes sur le tableau de
/// bord et dans l'historique.
(String, Color) etatDeLaVente(EtatVentePdv e) {
  final p = AtriumPalette.current;
  return switch (e) {
    EtatVentePdv.payee => ('Payée', p.success),
    EtatVentePdv.aPayer => ('À payer', p.warning),
    EtatVentePdv.enChambre => ('Sur la chambre', p.textSecondary),
  };
}

class OutletDashboardScreen extends ConsumerWidget {
  const OutletDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final agentId = session.agent?.id;
    if (agentId == null) {
      return const ModuleScaffold(title: _titre, body: SizedBox.shrink());
    }

    return ref
        .watch(perimetrePdvProvider(agentId))
        .when(
          loading: () => const ModuleScaffold(
            title: _titre,
            body: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => ModuleScaffold(
            title: _titre,
            body: EmptyState(
              icon: PhosphorIconsLight.warningCircle,
              title: 'Lecture impossible',
              message: '$e',
            ),
          ),
          data: (perimetre) => _Tableau(perimetre: perimetre, agentId: agentId),
        );
  }
}

class _Tableau extends ConsumerWidget {
  const _Tableau({required this.perimetre, required this.agentId});

  final PerimetrePdv perimetre;
  final String agentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acces = ref.watch(sessionProvider).acces;
    final choix = ref.watch(_choixProvider);

    // Les onglets Points de vente / Services : seulement ceux qui ont
    // quelque chose a montrer a cet agent.
    final genres = [
      for (final g in OutletKind.values)
        if (perimetre.duGenre(g).isNotEmpty && acces.voitGenre(g.name)) g,
    ];
    if (genres.isEmpty) {
      return const ModuleScaffold(
        title: _titre,
        body: EmptyState(
          icon: PhosphorIconsLight.shoppingBagOpen,
          title: 'Aucun point de vente',
          message:
              'Les points de vente arrivent du serveur : lancez une '
              'synchronisation.',
        ),
      );
    }
    final genre = genres.contains(choix.genre) ? choix.genre! : genres.first;
    final points = perimetre.duGenre(genre);
    final choisi = points.where((o) => o.id == choix.pointDeVente).firstOrNull;
    final filtres = FiltresPdv(
      pointsDeVente: choisi == null ? [for (final o in points) o.id] : [choisi.id],
      periode: choix.periode,
      reference: businessDayFor(DateTime.now()),
    );

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final notifier = ref.read(_choixProvider.notifier);

    final libelles = {for (final o in points) o.id: o.label};

    return ModuleScaffold(
      title: _titre,
      subtitle: perimetre.rattache
          ? points.map((o) => o.label).join(', ')
          : 'Tous les points de vente de l’hôtel',
      action: PillButton(
        label: 'Historique',
        icon: PhosphorIconsLight.clockCounterClockwise,
        tone: PillTone.quiet,
        onPressed: () => context.go('/ventes/historique'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
            child: Wrap(
              spacing: 16,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (genres.length > 1)
                  FilterPills<OutletKind>(
                    selected: genre,
                    onChanged: notifier.genre,
                    options: [
                      for (final g in genres)
                        FilterOption(
                          g,
                          g == OutletKind.OUTLET ? 'Points de vente' : 'Services',
                        ),
                    ],
                  ),
                // Un menu deroulant, comme au Stock et au point de vente (18
                // octobre) : une pastille par point de vente ne tenait plus
                // sur une ligne.
                if (points.length > 1)
                  ChoixEnMenu<String?>(
                    choisi: choisi?.id,
                    onChoisi: notifier.pointDeVente,
                    compte: genre == OutletKind.SERVICE
                        ? '${points.length} services'
                        : '${points.length} points de vente',
                    options: [
                      OptionMenu(
                        null,
                        genre == OutletKind.SERVICE
                            ? 'Tous les services'
                            : 'Tous les points de vente',
                        icone: PhosphorIconsLight.squaresFour,
                        genre: genre == OutletKind.SERVICE
                            ? 'Services'
                            : 'Points de vente',
                      ),
                      for (final o in points)
                        OptionMenu(
                          o.id,
                          o.label,
                          icone: genre == OutletKind.SERVICE
                              ? PhosphorIconsLight.bell
                              : PhosphorIconsLight.storefront,
                          genre: genre == OutletKind.SERVICE
                              ? 'Service'
                              : 'Point de vente',
                        ),
                    ],
                  ),
                FilterPills<PeriodePdv>(
                  selected: choix.periode,
                  onChanged: notifier.periode,
                  options: const [
                    FilterOption(PeriodePdv.jour, 'Aujourd’hui'),
                    FilterOption(PeriodePdv.semaine, 'Cette semaine'),
                    FilterOption(PeriodePdv.mois, 'Ce mois'),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ref
                .watch(tableauDeBordPdvProvider(filtres))
                .when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => EmptyState(
                    icon: PhosphorIconsLight.warningCircle,
                    title: 'Lecture impossible',
                    message: '$e',
                  ),
                  data: (t) => TableauAnime(
                    cle: filtres,
                    builder: (context, trace, barres) => ListView(
                      padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
                      children: [
                        _Bandeau(tableau: t, progres: trace),
                        const SizedBox(height: 16),
                        DeuxColonnes(
                          flexGauche: 3,
                          flexDroite: 2,
                          gauche: _RecetteParJour(
                            filtres: filtres,
                            progres: barres,
                          ),
                          droite: _Reglements(tableau: t, progres: barres),
                        ),
                        // Le comparatif : pour qui couvre tout l'hotel,
                        // quand il regarde tous les points de vente a la
                        // fois.
                        if (!perimetre.rattache &&
                            choisi == null &&
                            points.length > 1) ...[
                          const SizedBox(height: 16),
                          _Comparatif(
                            filtres: filtres,
                            libelles: libelles,
                            onChoisir: notifier.pointDeVente,
                          ),
                        ],
                        const SizedBox(height: 16),
                        DeuxColonnes(
                          gauche: _HeuresDePointe(tableau: t),
                          droite: _MeilleuresVentes(
                            tableau: t,
                            progres: barres,
                          ),
                        ),
                        const SizedBox(height: 16),
                        DeuxColonnes.empilees(
                          gauches: [
                            _DernieresVentes(
                              pointsDeVente: filtres.pointsDeVente,
                              libelles: libelles,
                            ),
                          ],
                          droites: [
                            _Tiroirs(
                              filtres: filtres,
                              libelles: libelles,
                              agentId: agentId,
                            ),
                            if (acces.peut('stock.read'))
                              _Stock(filtres: filtres),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

// --- Le bandeau -------------------------------------------------------------------

/// La recette en grand, sa courbe des quatorze derniers jours, son ecart a
/// la periode d'avant ; a cote, ce qui l'explique.
class _Bandeau extends ConsumerWidget {
  const _Bandeau({required this.tableau, required this.progres});

  final TableauDeBordPdv tableau;
  final Animation<double> progres;

  String get _repere => switch (tableau.filtres.periode) {
    PeriodePdv.jour => 'hier',
    PeriodePdv.semaine => 'la semaine dernière',
    PeriodePdv.mois => 'le mois dernier',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = tableau.filtres;
    final c = tableau.chiffres;
    final av = tableau.precedent;
    final courbe =
        ref
            .watch(
              _recetteParJourProvider((
                f.pointsDeVente.join(','),
                f.reference.subtract(const Duration(days: 13)),
                f.reference,
              )),
            )
            .value;
    return BandeauChiffres(
      libelle: switch (f.periode) {
        PeriodePdv.jour => 'Recette du jour',
        PeriodePdv.semaine => 'Recette de la semaine',
        PeriodePdv.mois => 'Recette du mois',
      },
      valeur: formatAmount(c.recette),
      variation: variationEnPourcent(c.recette, av.recette),
      repere: _repere,
      courbe: courbe,
      descriptionCourbe: 'Recette des quatorze derniers jours',
      progres: progres,
      mesures: [
        Mesure(
          'Ventes',
          '${c.ventes}',
          aide: _ecart(c.ventes, av.ventes) ?? 'Un client servi dans la journée',
        ),
        Mesure(
          'Ticket moyen',
          formatAmount(c.ticketMoyen),
          aide: _ecart(c.ticketMoyen, av.ticketMoyen),
        ),
        Mesure(
          'Articles',
          '${c.articles}',
          aide: _ecart(c.articles, av.articles),
        ),
        Mesure(
          'Payé sur place',
          formatAmount(c.surPlace),
          aide: 'Ardoises payées au comptoir',
        ),
        Mesure(
          'Ardoises à payer',
          formatAmount(c.aPayer),
          aide: 'Servi, le client paiera à la fin',
        ),
        Mesure(
          'Porté aux chambres',
          formatAmount(c.enChambre),
          aide: 'Encaissé au départ du client',
        ),
      ],
    );
  }

  /// « +12 % par rapport à hier », le signe dit le sens.
  String? _ecart(int maintenant, int avant) {
    final v = variationEnPourcent(maintenant, avant);
    return v == null ? null : '${v > 0 ? '+' : ''}$v % par rapport à $_repere';
  }
}

// --- La recette jour par jour -------------------------------------------------------

/// Une colonne par journee : la periode, et au moins la semaine ecoulee --
/// un lundi, une colonne seule ne dirait rien.
class _RecetteParJour extends ConsumerWidget {
  const _RecetteParJour({required this.filtres, required this.progres});

  final FiltresPdv filtres;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semaine = filtres.reference.subtract(const Duration(days: 6));
    final du = filtres.du.isAfter(semaine) ? semaine : filtres.du;
    final valeurs =
        ref
            .watch(
              _recetteParJourProvider((
                filtres.pointsDeVente.join(','),
                du,
                filtres.reference,
              )),
            )
            .value ??
        const <int>[];
    DateTime jour(int i) => DateTime(du.year, du.month, du.day + i);
    final total = valeurs.fold(0, (s, v) => s + v);
    return CarteSection(
      centrer: true,
      titre: 'Recette jour par jour',
      icone: PhosphorIconsLight.chartBar,
      description: total == 0
          ? null
          : 'Meilleure journée : ${_meilleure(valeurs, jour)}',
      child: SizedBox(
        height: 210,
        child: total == 0
            ? const SectionVide('Aucune vente sur ces journées.')
            : ColonnesRapport(
                progres: progres,
                series: [
                  SerieCourbe('Recette', valeurs, AtriumChartColors.current),
                ],
                lire: (i) =>
                    '${formatWeekdayShort(jour(i))} ${formatDayMonth(jour(i))} : '
                    '${formatAmount(valeurs[i])}',
                description: 'Recette jour par jour',
                etiquetteDebut: formatDayMonth(du),
                etiquetteFin: formatDayMonth(filtres.reference),
              ),
      ),
    );
  }

  static String _meilleure(List<int> v, DateTime Function(int) jour) {
    var i = 0;
    for (var k = 1; k < v.length; k++) {
      if (v[k] > v[i]) i = k;
    }
    return '${formatWeekdayShort(jour(i))} ${formatDayMonth(jour(i))}, '
        '${formatAmount(v[i])}';
  }
}

// --- Les reglements -----------------------------------------------------------------

/// Comment les clients paient : sur place, a la fin (ardoise ouverte), ou
/// au depart (porte sur la chambre). Trois parts d'un meme tout.
class _Reglements extends StatelessWidget {
  const _Reglements({required this.tableau, required this.progres});

  final TableauDeBordPdv tableau;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final c = tableau.chiffres;
    return CarteSection(
      centrer: true,
      titre: 'Comment les clients paient',
      icone: PhosphorIconsLight.chartDonut,
      child: AnneauRapport(
        progres: progres,
        libelleTotal: 'vendu',
        description: 'Recette par façon de payer',
        vide: 'Aucune vente sur la période.',
        parts: [
          PartAnneau('Payé sur place', c.surPlace, AtriumChartColors.parts[0]),
          PartAnneau('Ardoises à payer', c.aPayer, AtriumChartColors.parts[1]),
          PartAnneau(
            'Porté aux chambres',
            c.enChambre,
            AtriumChartColors.parts[2],
          ),
        ],
      ),
    );
  }
}

// --- Les dernieres ventes -----------------------------------------------------------

/// Ce qui vient d'etre servi, a qui, et ou en est l'argent ; l'historique
/// complet a un clic.
class _DernieresVentes extends ConsumerWidget {
  const _DernieresVentes({
    required this.pointsDeVente,
    required this.libelles,
  });

  final List<String> pointsDeVente;
  final Map<String, String> libelles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ventes =
        ref.watch(_dernieresVentesProvider(pointsDeVente.join(','))).value ??
        const <VenteHistorique>[];
    return CarteSection(
      titre: 'Dernières ventes',
      icone: PhosphorIconsLight.receipt,
      action: LienSection(
        libelle: 'Tout l’historique',
        icone: PhosphorIconsLight.clockCounterClockwise,
        onPressed: () => context.go('/ventes/historique'),
      ),
      child: ventes.isEmpty
          ? const SectionVide('Aucune vente pour l’instant.')
          : Column(
              children: [
                for (final v in ventes)
                  LigneHistorique(
                    entree: entreeDeVente(v, libelles[v.pointDeVente]),
                  ),
              ],
            ),
    );
  }
}

/// Une vente mise en mots pour la chronologie.
EntreeHistorique entreeDeVente(VenteHistorique v, String? pointDeVente) {
  final p = AtriumPalette.current;
  final (etat, couleur) = etatDeLaVente(v.etat);
  return EntreeHistorique(
    id: '${v.ardoiseId}|${formatIsoDate(v.jour)}',
    moment: v.moment ?? DateTime(v.jour.year, v.jour.month, v.jour.day, 12),
    icone: v.etat == EtatVentePdv.enChambre
        ? PhosphorIconsLight.bed
        : PhosphorIconsLight.receipt,
    couleur: p.accent,
    titre: v.titre,
    detail: [
      v.articles,
      ?pointDeVente,
      if (v.agent != null) 'servi par ${v.agent}',
    ].join(', '),
    montant: formatAmount(v.montant),
    etat: etat,
    couleurEtat: couleur,
  );
}

// --- Le comparatif ----------------------------------------------------------------

/// Tous les points de vente cote a cote. Une seule mesure en barre -- la
/// part de la recette --, une seule teinte : ce n'est pas l'identite du
/// point de vente qui se lit dans la couleur, c'est son poids. Toucher une
/// ligne ouvre ce point de vente.
class _Comparatif extends ConsumerWidget {
  const _Comparatif({
    required this.filtres,
    required this.libelles,
    required this.onChoisir,
  });

  final FiltresPdv filtres;
  final Map<String, String> libelles;
  final ValueChanged<String?> onChoisir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final lignes = ref.watch(comparatifPdvProvider(filtres)).value ?? const [];
    final total = lignes.fold(0, (s, l) => s + l.chiffres.recette);
    final style = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14.5,
      color: p.text,
      fontFeatures: tabularFigures,
    );
    final doux = style.copyWith(fontSize: 12.5, color: p.textSecondary);

    return CarteSection(
      titre: 'Comparatif des points de vente',
      icone: PhosphorIconsLight.storefront,
      description: 'Touchez un point de vente pour ne regarder que lui.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lignes)
            HoverRow(
              onTap: () => onChoisir(l.pointDeVente),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Semantics(
                button: true,
                label: 'Ouvrir ${libelles[l.pointDeVente] ?? 'ce point de vente'}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            libelles[l.pointDeVente] ?? 'Point de vente',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          formatAmount(l.chiffres.recette),
                          style: style.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // La part de la recette de l'hotel.
                    LayoutBuilder(
                      builder: (context, zone) => Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 8,
                          width: total == 0
                              ? 0
                              : zone.maxWidth * l.chiffres.recette / total,
                          decoration: BoxDecoration(
                            color: p.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (total > 0)
                          '${(l.chiffres.recette * 100 / total).round()} % de la recette',
                        '${l.chiffres.ventes} vente${l.chiffres.ventes > 1 ? 's' : ''}',
                        'ticket moyen ${formatAmount(l.chiffres.ticketMoyen)}',
                        if (_variation(l) case final v?) v,
                      ].join(' · '),
                      style: doux,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String? _variation(LigneComparatif l) {
    final avant = l.precedent.recette;
    if (avant == 0) return null;
    final v = ((l.chiffres.recette - avant) * 100 / avant).round();
    return '${v > 0 ? '+' : ''}$v % sur la période précédente';
  }
}

// --- Les heures de pointe ----------------------------------------------------------

/// Un histogramme de la journee type de la periode : une seule serie, une
/// seule teinte, sans legende -- le titre la nomme. Le montant de chaque
/// heure dans son info-bulle ; seule la pointe est etiquetee.
class _HeuresDePointe extends StatelessWidget {
  const _HeuresDePointe({required this.tableau});

  final TableauDeBordPdv tableau;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    int mesure(HeurePdv h) => h.montant;
    String dire(int n) => formatAmount(n);

    final actives = tableau.parHeure.where((h) => mesure(h) > 0).toList();
    if (actives.isEmpty) {
      return const CarteSection(
        centrer: true,
        titre: 'Heures de pointe',
        icone: PhosphorIconsLight.clock,
        child: SectionVide('Aucune vente sur la période.'),
      );
    }
    // De la premiere a la derniere heure de vente : la nuit vide ne
    // ecrase pas les barres du service.
    final debut = actives.first.heure;
    final fin = actives.last.heure;
    final heures = tableau.parHeure.sublist(debut, fin + 1);
    final max = heures.map(mesure).reduce((a, b) => a > b ? a : b);
    final pointe = heures.firstWhere((h) => mesure(h) == max);

    return CarteSection(
      centrer: true,
      titre: 'Heures de pointe',
      icone: PhosphorIconsLight.clock,
      description: 'Pointe à ${pointe.heure} h : ${dire(max)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final h in heures)
                  Expanded(
                    child: Tooltip(
                      message: '${h.heure} h – ${h.heure + 1} h : ${dire(mesure(h))}',
                      child: Padding(
                        // L'espace de surface entre deux barres.
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              height: max == 0 ? 0 : 120 * mesure(h) / max,
                              decoration: BoxDecoration(
                                color: h == pointe
                                    ? p.primary
                                    : p.primary.withValues(alpha: 0.45),
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(4),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // La ligne de base et quelques reperes d'heure, en retrait.
          Container(height: 1, color: p.border),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final h in heures)
                Expanded(
                  child: Text(
                    h.heure % 3 == 0 || h == pointe ? '${h.heure} h' : '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 11,
                      color: p.textSecondary,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// --- Les tiroirs ----------------------------------------------------------------

/// Les tiroirs : qui tient la caisse, depuis quand, et ou en est le
/// versement du soir -- declare par l'agent, recu par la reception.
class _Tiroirs extends ConsumerWidget {
  const _Tiroirs({
    required this.filtres,
    required this.libelles,
    required this.agentId,
  });

  final FiltresPdv filtres;
  final Map<String, String> libelles;
  final String agentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final tiroirs = ref.watch(tiroirsPdvProvider(filtres)).value ?? const [];
    final doux = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 13,
      color: p.textSecondary,
      fontFeatures: tabularFigures,
    );

    return CarteSection(
      titre: 'Tiroirs et versements',
      icone: PhosphorIconsLight.cashRegister,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (tiroirs.isEmpty)
            Text('Aucun tiroir ouvert ni versement sur la période.', style: doux),
          for (final t in tiroirs)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      t.ouvert
                          ? PhosphorIconsLight.lockSimpleOpen
                          : t.enAttente
                          ? PhosphorIconsLight.hourglass
                          : PhosphorIconsLight.checkCircle,
                      size: 20,
                      color: p.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${libelles[t.pointDeVente] ?? 'Point de vente'} · '
                          '${_qui(t)}',
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(_etat(t), style: doux),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _qui(TiroirPdv t) =>
      t.agentId == agentId ? 'Vous' : (t.agent ?? 'Un collègue');

  String _etat(TiroirPdv t) {
    final parts = <String>[];
    if (t.ouvert) {
      parts.add(
        t.ouvertLe == null
            ? 'Ouvert'
            : 'Ouvert depuis ${_heure(t.ouvertLe!)}',
      );
      parts.add('fond ${formatAmount(t.fond)}');
      parts.add('attendu ${formatAmount(t.attendu)}');
      return parts.join(' · ');
    }
    if (t.declare != null) parts.add('versé ${formatAmount(t.declare!)}');
    if (t.enAttente) {
      parts.add('en attente de la réception');
      if (t.declare != null) {
        parts.add('attendu ${formatAmount(t.attendu)}');
        final ecart = t.declare! - t.attendu;
        if (ecart != 0) parts.add('écart ${_signe(ecart)}');
      }
    } else if (t.recu != null) {
      parts.add('reçu ${formatAmount(t.recu!)}');
      final ecart = t.declare == null ? 0 : t.recu! - t.declare!;
      if (ecart != 0) parts.add('écart ${_signe(ecart)}');
    }
    return parts.isEmpty ? 'Fermé' : parts.join(' · ');
  }

  static String _signe(int montant) =>
      '${montant > 0 ? '+' : '−'}${formatAmount(montant.abs())}';

  static String _heure(DateTime instant) {
    final l = instant.toLocal();
    return '${l.hour} h ${l.minute.toString().padLeft(2, '0')}';
  }
}

// --- Le stock -------------------------------------------------------------------

/// Ce qui manque au magasin du point de vente, et les ravitaillements qui
/// attendent le controleur ou le comptable.
class _Stock extends ConsumerWidget {
  const _Stock({required this.filtres});

  final FiltresPdv filtres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final stock = ref.watch(stockPdvProvider(filtres)).value ?? const StockPdv();
    final style = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14.5,
      color: p.text,
      fontFeatures: tabularFigures,
    );
    final doux = style.copyWith(fontSize: 13, color: p.textSecondary);

    return CarteSection(
      titre: 'Stock',
      icone: PhosphorIconsLight.archive,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (stock.bas.isEmpty)
            Text('Rien sous le seuil.', style: doux)
          else
            for (final s in stock.bas)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      PhosphorIconsLight.warningCircle,
                      size: 18,
                      // Une alerte : le sens est aussi dans le texte.
                      color: s.quantite < 0 ? p.error : p.warning,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${s.produit} · ${s.magasin}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    Text(
                      s.quantite < 0
                          ? '${s.quantite} ${s.unite} (négatif)'
                          : '${s.quantite} / ${s.seuil} ${s.unite}',
                      style: style.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 12),
          Text(
            stock.transferts.isEmpty
                ? 'Aucun ravitaillement en attente.'
                : 'Ravitaillements en attente de validation',
            style: stock.transferts.isEmpty
                ? doux
                : style.copyWith(fontWeight: FontWeight.w600),
          ),
          for (final t in stock.transferts)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${t.quantite} ${t.unite} ${t.produit} · ${t.depuis} → ${t.vers}',
                style: doux,
              ),
            ),
        ],
      ),
    );
  }
}

// --- Les meilleures ventes ---------------------------------------------------------

/// Les articles qui rapportent le plus, en barres : le libelle et le
/// montant en toutes lettres, la quantite a cote.
class _MeilleuresVentes extends StatelessWidget {
  const _MeilleuresVentes({required this.tableau, required this.progres});

  final TableauDeBordPdv tableau;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    return CarteSection(
      centrer: true,
      titre: 'Meilleures ventes',
      icone: PhosphorIconsLight.sparkle,
      child: BarresParts(
        couleur: AtriumChartColors.current,
        progres: progres,
        vide: 'Aucune vente sur la période.',
        parts: [
          for (final l in tableau.meilleuresVentes.take(6))
            BarrePart(
              l.libelle,
              l.montant,
              formatAmount(l.montant),
              detail: '× ${l.quantite}',
            ),
        ],
      ),
    );
  }
}
