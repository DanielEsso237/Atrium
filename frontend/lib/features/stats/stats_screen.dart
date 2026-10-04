/// Statistiques : la tendance, la ou l'accueil donne l'instant.
///
/// L'accueil repond a « que dois-je faire maintenant ? ». Ici on regarde la
/// semaine : l'occupation qui monte ou baisse, la repartition par categorie,
/// l'heure a laquelle arrivent les clients, et le fil de ce qui s'est passe.
///
/// Les donnees et les graphiques sont ceux de l'ancien tableau de bord
/// (`dashboard_screen.dart`, `dashboard_charts.dart`) ; seule la mise en page
/// change. L'ancien ecran portait sa propre barre laterale, en doublon de la
/// navigation de la coque : elle disparait.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/queries/dashboard_queries.dart';
import '../auth/session.dart';
import '../dashboard/dashboard_charts.dart';
import '../dashboard/dashboard_screen.dart'
    show
        dashboardProvider,
        historiqueProvider,
        repartitionProvider,
        activiteDuJourProvider,
        dernieresActivitesProvider,
        notificationsProvider,
        notificationsNonLuesProvider,
        periodeOccupationProvider;

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen>
    with SingleTickerProviderStateMixin {
  /// Une seule sequence a l'arrivee : les courbes se tracent, l'anneau se
  /// referme, les barres montent. Ensuite, rien ne bouge sans raison.
  late final _entree = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final _courbes = CurvedAnimation(
    parent: _entree,
    curve: const Interval(0.1, 0.8, curve: atriumSpring),
  );
  late final _anneau = CurvedAnimation(
    parent: _entree,
    curve: const Interval(0.25, 0.9, curve: atriumSpring),
  );
  late final _barres = CurvedAnimation(
    parent: _entree,
    curve: const Interval(0.4, 1, curve: Curves.easeOutBack),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entree.isAnimating || _entree.isCompleted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _entree.value = 1;
    } else {
      _entree.forward();
    }
  }

  @override
  void dispose() {
    for (final a in [_courbes, _anneau, _barres]) {
      a.dispose();
    }
    _entree.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resume = ref.watch(dashboardProvider).value;
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final jour = businessDayFor(DateTime.now());

    return ModuleScaffold(
      title: 'Statistiques',
      subtitle: 'Journée du ${formatLongDate(jour)}',
      action: const NotificationBell(),
      body: LayoutBuilder(
        builder: (context, c) {
          final large = c.maxWidth >= 900;
          final kpis = _Kpis(resume: resume, progres: _courbes);
          final occupation = _CarteOccupation(
            resume: resume,
            progres: _courbes,
          );
          final repartition = _CarteRepartition(
            occupees: resume?.chambresOccupees ?? 0,
            progres: _anneau,
          );
          final activite = _CarteActivite(progres: _barres);
          const fil = _CarteFil();

          Widget paire(Widget a, Widget b, int fa, int fb, double h) => large
              ? SizedBox(
                  height: h,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: fa, child: a),
                      const SizedBox(width: 16),
                      Expanded(flex: fb, child: b),
                    ],
                  ),
                )
              : Column(
                  children: [
                    SizedBox(height: h, child: a),
                    const SizedBox(height: 16),
                    SizedBox(height: h, child: b),
                  ],
                );

          return ListView(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 36),
            children: [
              FadeUp(child: kpis),
              const SizedBox(height: 16),
              FadeUp(
                index: 1,
                child: paire(occupation, repartition, 3, 2, 360),
              ),
              const SizedBox(height: 16),
              FadeUp(index: 2, child: paire(activite, fil, 3, 2, 340)),
            ],
          );
        },
      ),
    );
  }
}

// --- Chiffres ----------------------------------------------------------------

class _Kpis extends ConsumerWidget {
  const _Kpis({required this.resume, required this.progres});

  final DashboardSummary? resume;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = resume;
    final historique = ref.watch(historiqueProvider(7)).value;
    List<int> serie(int Function(JourneeStats) f, [int? aujourdhui]) {
      if (historique == null || historique.isEmpty) return List.filled(7, 0);
      final valeurs = [for (final j in historique) f(j)];
      // Le dernier point parle comme le chiffre du jour, pas comme la
      // requete d'historique.
      if (aujourdhui != null) valeurs[valeurs.length - 1] = aujourdhui;
      return valeurs;
    }

    final cartes = [
      _Kpi(
        titre: 'Occupation',
        icone: PhosphorIconsLight.bed,
        valeur: r?.tauxOccupation == null ? '—' : '${r!.tauxOccupation} %',
        detail: r == null
            ? ''
            : '${r.chambresOccupees} sur ${r.chambresTotal} chambres',
        serie: serie((j) => j.occupees, r?.chambresOccupees),
        couleur: AtriumChartColors.current,
        progres: progres,
        route: '/chambres',
      ),
      _Kpi(
        titre: 'Séjours en cours',
        icone: PhosphorIconsLight.calendarCheck,
        valeur: '${r?.reservationsActives ?? 0}',
        detail: 'réservations actives',
        serie: serie((j) => j.reservations),
        couleur: AtriumChartColors.previous,
        progres: progres,
        route: '/reservations',
      ),
      _Kpi(
        titre: 'Arrivées',
        icone: PhosphorIconsLight.signIn,
        valeur: '${r?.arriveesDuJour ?? 0}',
        detail: (r?.arriveesRestantes ?? 0) == 0
            ? 'toutes enregistrées'
            : '${r!.arriveesRestantes} encore attendue'
                  '${r.arriveesRestantes > 1 ? 's' : ''}',
        serie: serie((j) => j.arrivees, r?.arriveesDuJour),
        couleur: AtriumChartColors.arrivals,
        progres: progres,
        route: '/reservations',
      ),
      _Kpi(
        titre: 'Départs',
        icone: PhosphorIconsLight.signOut,
        valeur: '${r?.departsDuJour ?? 0}',
        detail: (r?.departsRestants ?? 0) == 0
            ? 'tous enregistrés'
            : '${r!.departsRestants} encore à faire',
        serie: serie((j) => j.departs, r?.departsDuJour),
        couleur: AtriumChartColors.departures,
        progres: progres,
        route: '/reservations',
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final colonnes = c.maxWidth >= 900 ? 4 : 2;
        final lignes = <Widget>[];
        for (var i = 0; i < cartes.length; i += colonnes) {
          final rangee = cartes.skip(i).take(colonnes).toList();
          if (i > 0) lignes.add(const SizedBox(height: 14));
          lignes.add(
            SizedBox(
              height: 168,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var k = 0; k < rangee.length; k++) ...[
                    if (k > 0) const SizedBox(width: 14),
                    Expanded(child: rangee[k]),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(children: lignes);
      },
    );
  }
}

class _Kpi extends ConsumerWidget {
  const _Kpi({
    required this.titre,
    required this.icone,
    required this.valeur,
    required this.detail,
    required this.serie,
    required this.couleur,
    required this.progres,
    required this.route,
  });

  final String titre;
  final IconData icone;
  final String valeur;
  final String detail;
  final List<int> serie;
  final Color couleur;
  final Animation<double> progres;
  final String route;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final peut = ref.watch(sessionProvider).acces.peut('rooms.read');
    return Bezel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      onTap: peut ? () => context.go(route) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icone, size: 18, color: couleur),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: p.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            valeur,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.2,
              height: 1,
              color: p.text,
              fontFeatures: tabularFigures,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              color: p.textSecondary,
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 34,
            child: Sparkline(
              valeurs: serie,
              couleur: couleur,
              progres: progres,
              description: '$titre sur sept jours',
            ),
          ),
        ],
      ),
    );
  }
}

// --- Cartes graphiques -------------------------------------------------------

/// Le cadre commun des graphiques : titre, action a droite, corps.
class _Carte extends StatelessWidget {
  const _Carte({
    required this.titre,
    required this.icone,
    required this.child,
    this.action,
  });

  final String titre;
  final IconData icone;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 38,
            child: Row(
              children: [
                Icon(icone, size: 20, color: p.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    titre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: p.text,
                    ),
                  ),
                ),
                ?action,
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

Widget _attente() => Center(
  child: CircularProgressIndicator(
    strokeWidth: 2.5,
    color: AtriumColors.mintStrong,
  ),
);

class _CarteOccupation extends ConsumerWidget {
  const _CarteOccupation({required this.resume, required this.progres});

  final DashboardSummary? resume;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periode = ref.watch(periodeOccupationProvider);
    final historique = ref.watch(historiqueProvider(periode * 2)).value;
    final total = resume?.chambresTotal ?? 0;

    int taux(int occupees) =>
        total == 0 ? 0 : (occupees * 100 / total).round().clamp(0, 100);

    final Widget corps;
    if (historique == null || historique.length < periode * 2) {
      corps = _attente();
    } else {
      final precedent = historique.take(periode).toList();
      final actuel = historique.skip(periode).toList();
      final valeurs = [for (final j in actuel) taux(j.occupees)];
      if (resume?.tauxOccupation != null) {
        valeurs[valeurs.length - 1] = resume!.tauxOccupation!;
      }
      final (libelleActuel, libellePrecedent) = periode == 7
          ? ('Cette semaine', 'Semaine précédente')
          : ('$periode derniers jours', '$periode jours précédents');
      corps = OccupationChart(
        jours: [for (final j in actuel) j.jour],
        actuel: valeurs,
        precedent: [for (final j in precedent) taux(j.occupees)],
        progres: progres,
        libelleActuel: libelleActuel,
        libellePrecedent: libellePrecedent,
      );
    }

    return _Carte(
      titre: "Taux d'occupation",
      icone: PhosphorIconsLight.chartLineUp,
      action: _Periode(
        valeur: periode,
        onChanged: ref.read(periodeOccupationProvider.notifier).choisir,
      ),
      child: corps,
    );
  }
}

/// 7, 14 ou 30 jours : une petite bascule plutot qu'un menu.
class _Periode extends StatelessWidget {
  const _Periode({required this.valeur, required this.onChanged});

  final int valeur;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.surfaceMuted,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final j in const [7, 14, 30])
            GestureDetector(
              onTap: () => onChanged(j),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: AtriumMotion.of(
                    context,
                    const Duration(milliseconds: 300),
                  ),
                  curve: atriumSpring,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: j == valeur ? p.selected : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '$j j',
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: j == valeur ? p.onSelected : p.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CarteRepartition extends ConsumerWidget {
  const _CarteRepartition({required this.occupees, required this.progres});

  final int occupees;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = ref.watch(repartitionProvider).value;
    return _Carte(
      titre: 'Par catégorie',
      icone: PhosphorIconsLight.chartDonut,
      child: types == null
          ? _attente()
          : RepartitionDonut(
              types: types,
              occupees: occupees,
              progres: progres,
            ),
    );
  }
}

class _CarteActivite extends ConsumerWidget {
  const _CarteActivite({required this.progres});

  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activite = ref.watch(activiteDuJourProvider).value;
    return _Carte(
      titre: 'Arrivées et départs, heure par heure',
      icone: PhosphorIconsLight.clock,
      child: activite == null
          ? _attente()
          : ActiviteBarres(
              activite: activite,
              trancheCourante: trancheHoraire(DateTime.now().hour),
              progres: progres,
            ),
    );
  }
}

/// Le fil de ce qui s'est passe : reservations, arrivees, departs, commandes.
class _CarteFil extends ConsumerWidget {
  const _CarteFil();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activites = ref.watch(dernieresActivitesProvider).value;
    return _Carte(
      titre: 'Dernières activités',
      icone: PhosphorIconsLight.pulse,
      action: activites == null || activites.isEmpty
          ? null
          : TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  icon: const Icon(PhosphorIconsLight.pulse, size: 30),
                  title: const Text('Dernières activités'),
                  content: SizedBox(
                    width: 480,
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final a in activites) _LigneActivite(activite: a),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Fermer'),
                    ),
                  ],
                ),
              ),
              child: const Text('Voir tout'),
            ),
      child: activites == null
          ? _attente()
          : activites.isEmpty
          ? Center(
              child: Text(
                'Réservations, arrivées, départs et commandes apparaîtront '
                'ici.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 14,
                  color: AtriumColors.textSecondary,
                ),
              ),
            )
          : ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final a in activites.take(12)) _LigneActivite(activite: a),
              ],
            ),
    );
  }
}

class _LigneActivite extends StatelessWidget {
  const _LigneActivite({required this.activite});

  final Activite activite;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final a = activite;
    final (titre, icone, couleur) = switch (a.genre) {
      GenreActivite.reservation => (
        'Nouvelle réservation',
        PhosphorIconsLight.calendarPlus,
        AtriumChartColors.current,
      ),
      GenreActivite.arrivee => (
        'Arrivée enregistrée',
        PhosphorIconsLight.signIn,
        AtriumChartColors.arrivals,
      ),
      GenreActivite.depart => (
        'Départ effectué',
        PhosphorIconsLight.signOut,
        AtriumChartColors.departures,
      ),
      GenreActivite.commande => (
        'Commande ${a.pointDeVente?.toLowerCase() ?? 'restaurant'}',
        PhosphorIconsLight.forkKnife,
        AtriumChartColors.previous,
      ),
    };
    final lieu = a.chambre != null
        ? 'Chambre ${a.chambre}'
        : (a.typeChambre != null ? 'Chambre ${a.typeChambre}' : null);
    final detail = [lieu, a.client].whereType<String>().join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: couleur.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icone, size: 18, color: couleur),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
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
          const SizedBox(width: 8),
          Text(
            heureActivite(a.moment),
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              color: p.textSecondary,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}

/// L'heure d'un evenement du jour, « Hier » pour la veille, la date au-dela.
String heureActivite(DateTime instant) {
  final local = instant.toLocal();
  final journee = businessDayFor(DateTime.now());
  final jourEvenement = businessDayFor(local);
  if (jourEvenement == journee) {
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
  if (journee.difference(jourEvenement).inDays == 1) return 'Hier';
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}';
}

// --- Notifications -----------------------------------------------------------

/// La cloche : le nombre de notifications non lues, et leur liste au toucher.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final nonLues = ref.watch(notificationsNonLuesProvider).value ?? 0;
    return Tooltip(
      message: nonLues == 0
          ? 'Notifications'
          : '$nonLues notification${nonLues > 1 ? 's' : ''} non lue'
                '${nonLues > 1 ? 's' : ''}',
      child: InkResponse(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => const _Notifications(),
        ),
        radius: 26,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(PhosphorIconsLight.bell, size: 24, color: p.text),
              if (nonLues > 0)
                Positioned(
                  top: 6,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: p.accent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      nonLues > 9 ? '9+' : '$nonLues',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: p.onAccent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notifications extends ConsumerWidget {
  const _Notifications();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final liste = ref.watch(notificationsProvider).value ?? const [];
    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.bell, size: 30),
      title: const Text('Notifications'),
      content: SizedBox(
        width: 440,
        child: liste.isEmpty
            ? Text(
                'Aucune notification pour le moment.',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textSecondary),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final n in liste)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(top: 6, right: 12),
                            decoration: BoxDecoration(
                              color: n.lue ? Colors.transparent : p.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  n.titre,
                                  style: TextStyle(
                                    fontFamily: atriumFontFamily,
                                    fontSize: 14.5,
                                    fontWeight: n.lue
                                        ? FontWeight.w500
                                        : FontWeight.w700,
                                    color: p.text,
                                  ),
                                ),
                                if (n.corps != null)
                                  Text(
                                    n.corps!,
                                    style: TextStyle(
                                      fontFamily: atriumFontFamily,
                                      fontSize: 13,
                                      color: p.textSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            heureActivite(n.moment),
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
