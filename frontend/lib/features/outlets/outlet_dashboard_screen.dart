/// Le tableau de bord des points de vente et des services.
///
/// Un seul ecran pour tous, parametre par le perimetre de l'agent : la
/// direction et la reception voient tout l'hotel, avec un filtre ; l'agent du
/// bar ne voit que le bar. Un point de vente cree demain y apparait de
/// lui-meme, sans une ligne de code.
///
/// L'argent encaisse et l'attendu des tiroirs s'affichent, tiroir ouvert ou
/// non (decision du 15 octobre, qui remplace le comptage a l'aveugle du 11).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/outlet_dashboard_queries.dart';
import '../../data/repositories/order_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

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

    return ModuleScaffold(
      title: _titre,
      subtitle: perimetre.rattache
          ? points.map((o) => o.label).join(', ')
          : 'Tous les points de vente de l’hôtel',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
            child: Wrap(
              spacing: 16,
              runSpacing: 10,
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
                if (points.length > 1)
                  FilterPills<String?>(
                    selected: choisi?.id,
                    onChanged: notifier.pointDeVente,
                    options: [
                      const FilterOption(null, 'Tous'),
                      for (final o in points) FilterOption(o.id, o.label),
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
                  data: (t) => ListView(
                    padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
                    children: [
                      _Chiffres(tableau: t),
                      // Le comparatif : pour qui couvre tout l'hotel, quand
                      // il regarde tous les points de vente a la fois.
                      if (!perimetre.rattache &&
                          choisi == null &&
                          points.length > 1) ...[
                        const SizedBox(height: 24),
                        _Comparatif(
                          filtres: filtres,
                          libelles: {for (final o in points) o.id: o.label},
                          onChoisir: notifier.pointDeVente,
                        ),
                      ],
                      const SizedBox(height: 24),
                      _HeuresDePointe(tableau: t),
                      const SizedBox(height: 24),
                      _MeilleuresVentes(tableau: t),
                      const SizedBox(height: 24),
                      _Tiroirs(
                        filtres: filtres,
                        libelles: {for (final o in points) o.id: o.label},
                        agentId: agentId,
                      ),
                      if (acces.peut('stock.read')) ...[
                        const SizedBox(height: 24),
                        _Stock(filtres: filtres),
                      ],
                    ],
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

// --- Les chiffres ---------------------------------------------------------------

class _Chiffres extends StatelessWidget {
  const _Chiffres({required this.tableau});

  final TableauDeBordPdv tableau;

  String get _repere => switch (tableau.filtres.periode) {
    PeriodePdv.jour => 'hier',
    PeriodePdv.semaine => 'la semaine dernière',
    PeriodePdv.mois => 'le mois dernier',
  };

  @override
  Widget build(BuildContext context) {
    final c = tableau.chiffres;
    final av = tableau.precedent;
    final tuiles = [
      _Tuile(
        libelle: 'Recette',
        valeur: formatAmount(c.recette),
        variation: _variation(c.recette, av.recette),
        repere: _repere,
      ),
      _Tuile(
        libelle: 'Ventes',
        valeur: '${c.ventes}',
        variation: _variation(c.ventes, av.ventes),
        repere: _repere,
        aide: 'Un client servi dans la journée',
      ),
      _Tuile(
        libelle: 'Ticket moyen',
        valeur: formatAmount(c.ticketMoyen),
        variation: _variation(c.ticketMoyen, av.ticketMoyen),
        repere: _repere,
      ),
      _Tuile(
        libelle: 'Articles',
        valeur: '${c.articles}',
        variation: _variation(c.articles, av.articles),
        repere: _repere,
      ),
      _Tuile(
        libelle: 'Payé sur place',
        valeur: formatAmount(c.surPlace),
        repere: _repere,
      ),
      _Tuile(
        libelle: 'Ardoises à payer',
        valeur: formatAmount(c.aPayer),
        repere: _repere,
        aide: 'Servi, le client paiera à la fin',
      ),
      _Tuile(
        libelle: 'Porté aux chambres',
        valeur: formatAmount(c.enChambre),
        repere: _repere,
        aide: 'Encaissé au départ du client',
      ),
    ];

    return LayoutBuilder(
      builder: (context, zone) {
        final colonnes = zone.maxWidth >= 900
            ? 3
            : zone.maxWidth >= 480
            ? 2
            : 1;
        const ecart = 12.0;
        final largeur = (zone.maxWidth - ecart * (colonnes - 1)) / colonnes;
        return Wrap(
          spacing: ecart,
          runSpacing: ecart,
          children: [
            for (final t in tuiles) SizedBox(width: largeur, child: t),
          ],
        );
      },
    );
  }

  /// En pour cent, arrondi ; `null` sans repere (rien la periode d'avant).
  static int? _variation(int maintenant, int avant) =>
      avant == 0 ? null : ((maintenant - avant) * 100 / avant).round();
}

class _Tuile extends StatelessWidget {
  const _Tuile({
    required this.libelle,
    required this.valeur,
    required this.repere,
    this.variation,
    this.aide,
  });

  final String libelle;

  /// `null` : rien a montrer.
  final String? valeur;
  final int? variation;
  final String repere;
  final String? aide;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final v = variation;
    return Bezel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            libelle,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          if (valeur == null)
            Semantics(
              label: '$libelle masqué jusqu’au versement',
              child: Row(
                children: [
                  Icon(PhosphorIconsLight.lockSimple, size: 22, color: p.textSecondary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Après le versement',
                      maxLines: 2,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 15,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            Text(
              valeur!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: atriumDisplay(28, color: p.text).copyWith(
                fontFeatures: tabularFigures,
              ),
            ),
          const SizedBox(height: 6),
          Text(
            v == null
                ? (aide ?? '')
                : '${v > 0 ? '+' : ''}$v % par rapport à $repere',
            maxLines: 2,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              // Le sens se lit dans le signe, pas dans la couleur seule.
              color: v == null
                  ? p.textSecondary
                  : v >= 0
                  ? p.success
                  : p.error,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
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

    return Bezel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Comparatif des points de vente'),
          const SizedBox(height: 4),
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
      return Bezel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Eyebrow('Heures de pointe'),
            const SizedBox(height: 8),
            Text(
              'Aucune vente sur la période.',
              style: TextStyle(fontFamily: atriumFontFamily, color: p.textSecondary),
            ),
          ],
        ),
      );
    }
    // De la premiere a la derniere heure de vente : la nuit vide ne
    // ecrase pas les barres du service.
    final debut = actives.first.heure;
    final fin = actives.last.heure;
    final heures = tableau.parHeure.sublist(debut, fin + 1);
    final max = heures.map(mesure).reduce((a, b) => a > b ? a : b);
    final pointe = heures.firstWhere((h) => mesure(h) == max);

    return Bezel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Eyebrow(
            'Heures de pointe',
            trailing: Text(
              'Pointe à ${pointe.heure} h : ${dire(max)}',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.text,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          const SizedBox(height: 16),
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

    return Bezel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Tiroirs et versements'),
          const SizedBox(height: 8),
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

    return Bezel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Stock'),
          const SizedBox(height: 8),
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

class _MeilleuresVentes extends StatelessWidget {
  const _MeilleuresVentes({required this.tableau});

  final TableauDeBordPdv tableau;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final lignes = tableau.meilleuresVentes;
    final style = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14.5,
      color: p.text,
      fontFeatures: tabularFigures,
    );
    return Bezel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Meilleures ventes'),
          const SizedBox(height: 8),
          if (lignes.isEmpty)
            Text(
              'Aucune vente sur la période.',
              style: style.copyWith(color: p.textSecondary),
            ),
          for (final (i, l) in lignes.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${i + 1}',
                      style: style.copyWith(color: p.textSecondary),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      l.libelle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                  Text('× ${l.quantite}', style: style),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 110,
                    child: Text(
                      formatAmount(l.montant),
                      textAlign: TextAlign.right,
                      style: style.copyWith(fontWeight: FontWeight.w600),
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
