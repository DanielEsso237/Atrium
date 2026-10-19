/// Le tableau de bord de l'entretien : le menage et la maintenance (demande
/// du 16 octobre, refait le 18).
///
/// Un clic sur « Entretien » ouvre cet ecran ; la fleche du menu deplie
/// Ménage, Maintenance et l'Historique de l'entretien. Chaque bloc ne
/// s'affiche qu'a qui lit son metier : la gouvernante voit le menage, le
/// technicien les pannes, la direction les deux.
///
/// Ce qu'il faut voir en arrivant : combien de chambres ont ete faites et
/// combien restent, lesquelles, qui fait quoi et en combien de temps ; les
/// pannes ouvertes, les urgentes d'abord, les chambres qu'elles bloquent, et
/// ce que les reparations ont coute.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/historique.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../core/widgets/tableau_de_bord.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/entretien_queries.dart';
import '../../data/local/queries/mouvements_queries.dart';
import '../auth/session.dart';
import '../reports/report_charts.dart';
import 'entretien_presentation.dart';

final _entretienProvider = StreamProvider<ResumeEntretien>(
  (ref) => ref.watch(databaseProvider).watchResumeEntretien(businessDateNow()),
);

/// Les quatorze derniers jours, et tout ce qui reste a faire.
final _tachesProvider = StreamProvider<List<TacheMenage>>((ref) {
  final debut = businessDayFor(
    DateTime.now(),
  ).subtract(const Duration(days: 13));
  return ref
      .watch(databaseProvider)
      .watchTachesMenage(depuis: formatIsoDate(debut));
});

/// Les trente derniers jours, et tout ce qui reste ouvert.
final _pannesProvider = StreamProvider<List<PanneEntretien>>(
  (ref) => ref
      .watch(databaseProvider)
      .watchPannes(depuis: DateTime.now().subtract(const Duration(days: 30))),
);

class EntretienScreen extends ConsumerWidget {
  const EntretienScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acces = ref.watch(sessionProvider).acces;
    final menage = acces.peut('housekeeping.read');
    final maintenance = acces.peut('maintenance.read');
    final r = ref.watch(_entretienProvider).value;
    final taches = menage
        ? ref.watch(_tachesProvider).value ?? const <TacheMenage>[]
        : const <TacheMenage>[];
    final pannes = maintenance
        ? ref.watch(_pannesProvider).value ?? const <PanneEntretien>[]
        : const <PanneEntretien>[];
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    // Les chambres faites, journee par journee, sur quatorze jours.
    final aujourdhui = businessDayFor(DateTime.now());
    final debut = aujourdhui.subtract(const Duration(days: 13));
    final parJour = List.filled(14, 0);
    for (final t in taches) {
      if (!t.faite) continue;
      final i = t.jour.difference(debut).inDays;
      if (i >= 0 && i < 14) parJour[i]++;
    }

    final ouvertes = [
      for (final m in pannes)
        if (m.ouverte) m,
    ]..sort((a, b) => a.priorite.index == b.priorite.index
          ? (a.signaleLe ?? DateTime(0)).compareTo(b.signaleLe ?? DateTime(0))
          : b.priorite.index.compareTo(a.priorite.index));

    final blocs = <Widget>[
      _Bandeau(
        resume: r,
        menage: menage,
        maintenance: maintenance,
        parJour: parJour,
        taches: taches,
        ouvertes: ouvertes,
      ),
      if (menage)
        DeuxColonnes(
          flexGauche: 3,
          flexDroite: 2,
          gauche: _MenageParJour(parJour: parJour, debut: debut),
          droite: _EtatDesChambres(resume: r),
        ),
      if (menage && maintenance)
        DeuxColonnes(
          gauche: _AFaire(taches: taches),
          droite: _PannesOuvertes(pannes: ouvertes),
        )
      else if (menage)
        _AFaire(taches: taches)
      else if (maintenance)
        _PannesOuvertes(pannes: ouvertes),
      if (menage && maintenance)
        DeuxColonnes(
          gauche: _ParAgent(taches: taches),
          droite: _Reparations(pannes: pannes),
        )
      else if (menage)
        _ParAgent(taches: taches)
      else if (maintenance)
        _Reparations(pannes: pannes),
      _Activite(taches: taches, pannes: pannes),
    ];

    return ModuleScaffold(
      title: 'Entretien',
      subtitle: 'Le ménage et la maintenance, en un coup d’œil',
      action: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          PillButton(
            label: 'Historique',
            icon: PhosphorIconsLight.clockCounterClockwise,
            tone: PillTone.quiet,
            onPressed: () => context.go('/entretien/historique'),
          ),
          if (menage)
            PillButton(
              label: 'Ménage',
              icon: PhosphorIconsLight.broom,
              tone: maintenance ? PillTone.quiet : PillTone.accent,
              onPressed: () => context.go('/menage'),
            ),
          if (maintenance)
            PillButton(
              label: 'Maintenance',
              icon: PhosphorIconsLight.wrench,
              tone: PillTone.accent,
              onPressed: () => context.go('/maintenance'),
            ),
        ],
      ),
      body: TableauAnime(
        builder: (context, trace, barres) => ListView(
          padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
          children: [
            for (final (i, b) in blocs.indexed) ...[
              if (i > 0) const SizedBox(height: 16),
              _Anime(trace: trace, barres: barres, child: b),
            ],
          ],
        ),
      ),
    );
  }
}

/// Transmet les deux temps de l'animation aux blocs qui tracent.
class _Anime extends InheritedWidget {
  const _Anime({
    required this.trace,
    required this.barres,
    required super.child,
  });

  final Animation<double> trace;
  final Animation<double> barres;

  static _Anime of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Anime>()!;

  @override
  bool updateShouldNotify(_Anime ancien) =>
      ancien.trace != trace || ancien.barres != barres;
}

// --- Le bandeau --------------------------------------------------------------------

class _Bandeau extends StatelessWidget {
  const _Bandeau({
    required this.resume,
    required this.menage,
    required this.maintenance,
    required this.parJour,
    required this.taches,
    required this.ouvertes,
  });

  final ResumeEntretien? resume;
  final bool menage;
  final bool maintenance;
  final List<int> parJour;
  final List<TacheMenage> taches;
  final List<PanneEntretien> ouvertes;

  @override
  Widget build(BuildContext context) {
    final r = resume;
    final urgentes = ouvertes.where((m) => m.urgente).length;
    final pannes = [
      Mesure(
        'Pannes ouvertes',
        '${ouvertes.length}',
        aide: urgentes == 0
            ? 'Aucune urgente'
            : '$urgentes urgente${urgentes > 1 ? 's' : ''}',
        alerte: urgentes > 0,
        onTap: () => context.go('/maintenance'),
      ),
      Mesure(
        'Hors service',
        '${r?.horsService ?? 0}',
        aide: 'Chambres qui ne se louent pas',
        alerte: (r?.horsService ?? 0) > 0,
      ),
    ];
    if (!menage) {
      return BandeauChiffres(
        libelle: 'Pannes ouvertes',
        valeur: '${ouvertes.length}',
        mesures: [
          Mesure(
            'Urgentes',
            '$urgentes',
            alerte: urgentes > 0,
          ),
          Mesure('En intervention', '${r?.enIntervention ?? 0}'),
          pannes.last,
          Mesure('Réglées sur 7 jours', '${r?.resolus7Jours ?? 0}'),
        ],
      );
    }
    final faites7 = [
      for (final t in taches)
        if (t.faite && t.duree != null && t.jour.isAfter(
          businessDayFor(DateTime.now()).subtract(const Duration(days: 7)),
        ))
          t.duree!,
    ];
    final moyenne = faites7.isEmpty
        ? null
        : (faites7.fold(0, (s, d) => s + d) / faites7.length).round();
    return BandeauChiffres(
      libelle: "Chambres faites aujourd'hui",
      valeur: '${parJour.last}',
      variation: variationEnPourcent(parJour.last, parJour[parJour.length - 2]),
      repere: 'hier',
      courbe: parJour,
      descriptionCourbe: 'Chambres faites ces quatorze derniers jours',
      progres: _Anime.of(context).trace,
      mesures: [
        Mesure(
          'À nettoyer',
          '${r?.sales ?? 0}',
          aide: (r?.nonAssignees ?? 0) == 0
              ? 'Toutes confiées'
              : '${r!.nonAssignees} sans femme de chambre',
          alerte: (r?.sales ?? 0) > 0,
          onTap: () => context.go('/menage'),
        ),
        Mesure('En cours', '${r?.enCours ?? 0}'),
        Mesure(
          'Chambres propres',
          '${r?.propres ?? 0} / ${r?.chambres ?? 0}',
        ),
        Mesure(
          'Durée moyenne',
          moyenne == null ? '—' : duree(moyenne),
          aide: 'Par chambre, sur 7 jours',
        ),
        if (maintenance) ...pannes,
      ],
    );
  }
}

// --- Le menage ---------------------------------------------------------------------

class _MenageParJour extends StatelessWidget {
  const _MenageParJour({required this.parJour, required this.debut});

  final List<int> parJour;
  final DateTime debut;

  @override
  Widget build(BuildContext context) {
    DateTime jour(int i) => DateTime(debut.year, debut.month, debut.day + i);
    final total = parJour.fold(0, (s, v) => s + v);
    return CarteSection(
      centrer: true,
      titre: 'Chambres faites jour par jour',
      icone: PhosphorIconsLight.chartBar,
      description: total == 0
          ? null
          : '$total chambres en quatorze jours, '
                '${(total / 14).toStringAsFixed(1).replaceAll('.', ',')} par jour',
      child: SizedBox(
        height: 200,
        child: total == 0
            ? const SectionVide('Aucune chambre faite sur ces journées.')
            : ColonnesRapport(
                progres: _Anime.of(context).barres,
                series: [
                  SerieCourbe('Chambres', parJour, AtriumChartColors.current),
                ],
                lire: (i) =>
                    '${formatWeekdayShort(jour(i))} ${formatDayMonth(jour(i))} : '
                    '${parJour[i]} chambre${parJour[i] > 1 ? 's' : ''}',
                description: 'Chambres faites jour par jour',
                etiquetteDebut: formatDayMonth(jour(0)),
                etiquetteFin: formatDayMonth(jour(13)),
              ),
      ),
    );
  }
}

class _EtatDesChambres extends StatelessWidget {
  const _EtatDesChambres({required this.resume});

  final ResumeEntretien? resume;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final r = resume;
    return CarteSection(
      centrer: true,
      titre: 'État des chambres',
      icone: PhosphorIconsLight.chartDonut,
      child: AnneauRapport(
        progres: _Anime.of(context).barres,
        libelleTotal: 'chambres',
        description: 'Chambres par état de propreté',
        vide: 'Aucune chambre.',
        ecrire: (n) => '$n',
        parts: [
          PartAnneau('Propres', r?.propres ?? 0, p.success),
          PartAnneau('À nettoyer', r?.sales ?? 0, p.warning),
          PartAnneau('En cours', r?.enCours ?? 0, AtriumChartColors.current),
        ],
      ),
    );
  }
}

class _AFaire extends StatelessWidget {
  const _AFaire({required this.taches});

  final List<TacheMenage> taches;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final aFaire = [
      for (final t in taches)
        if (t.aFaire) t,
    ]..sort((a, b) => b.priorite.index.compareTo(a.priorite.index));
    return CarteSection(
      titre: 'Chambres à faire',
      icone: PhosphorIconsLight.broom,
      description: aFaire.isEmpty
          ? null
          : 'Les plus pressées d’abord.',
      action: LienSection(
        libelle: 'Ouvrir le ménage',
        onPressed: () => context.go('/menage'),
      ),
      child: aFaire.isEmpty
          ? const SectionVide('Rien à faire : toutes les chambres sont prêtes.')
          : Column(
              children: [
                for (final (i, t) in aFaire.take(8).indexed) ...[
                  if (i > 0) Divider(height: 1, color: p.border),
                  _Ligne(
                    repere: t.chambre,
                    titre: libelleTypeMenage(t.type),
                    detail: t.agent == null
                        ? 'Personne n’en est chargé'
                        : '${libelleStatutTache(t.statut)}, ${t.agent}',
                    alerteDetail: t.agent == null,
                    etat: t.priorite == Priority.URGENT ||
                            t.priorite == Priority.HIGH
                        ? libellePriorite(t.priorite)
                        : null,
                    couleurEtat: couleurPriorite(t.priorite),
                  ),
                ],
                if (aFaire.length > 8)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Et ${aFaire.length - 8} de plus.',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 12.5,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ParAgent extends StatelessWidget {
  const _ParAgent({required this.taches});

  final List<TacheMenage> taches;

  @override
  Widget build(BuildContext context) {
    final depuis = businessDayFor(
      DateTime.now(),
    ).subtract(const Duration(days: 7));
    final parAgent = <String, List<TacheMenage>>{};
    for (final t in taches) {
      if (!t.faite || !t.jour.isAfter(depuis)) continue;
      parAgent.putIfAbsent(t.agent ?? 'Sans nom', () => []).add(t);
    }
    final tries = parAgent.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return CarteSection(
      titre: 'Qui a fait quoi',
      icone: PhosphorIconsLight.usersThree,
      description: 'Chambres faites ces sept derniers jours.',
      child: BarresParts(
        couleur: AtriumChartColors.current,
        progres: _Anime.of(context).barres,
        vide: 'Aucune chambre faite cette semaine.',
        parts: [
          for (final e in tries.take(6))
            BarrePart(
              e.key,
              e.value.length,
              '${e.value.length} chambre${e.value.length > 1 ? 's' : ''}',
              detail: _moyenne(e.value),
            ),
        ],
      ),
    );
  }

  static String? _moyenne(List<TacheMenage> t) {
    final d = [
      for (final x in t)
        if (x.duree != null) x.duree!,
    ];
    if (d.isEmpty) return null;
    return '${duree((d.fold(0, (s, v) => s + v) / d.length).round())} en moyenne';
  }
}

// --- La maintenance -----------------------------------------------------------------

class _PannesOuvertes extends StatelessWidget {
  const _PannesOuvertes({required this.pannes});

  final List<PanneEntretien> pannes;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return CarteSection(
      titre: 'Pannes ouvertes',
      icone: PhosphorIconsLight.wrench,
      description: pannes.isEmpty ? null : 'Les urgentes d’abord.',
      action: LienSection(
        libelle: 'Ouvrir la maintenance',
        onPressed: () => context.go('/maintenance'),
      ),
      child: pannes.isEmpty
          ? const SectionVide('Aucune panne ouverte.')
          : Column(
              children: [
                for (final (i, m) in pannes.take(8).indexed) ...[
                  if (i > 0) Divider(height: 1, color: p.border),
                  _Ligne(
                    titre: m.titre,
                    detail: [
                      m.ou,
                      libelleStatutPanne(m.statut),
                      if (m.signaleLe != null) _depuis(m.signaleLe!),
                    ].join(', '),
                    etat: libellePriorite(m.priorite),
                    couleurEtat: couleurPriorite(m.priorite),
                  ),
                ],
              ],
            ),
    );
  }

  /// « depuis 3 h », « depuis 2 jours ».
  static String _depuis(DateTime instant) {
    final d = DateTime.now().toUtc().difference(instant.toUtc());
    if (d.inHours < 1) return 'à l’instant';
    if (d.inHours < 48) return 'depuis ${d.inHours} h';
    return 'depuis ${d.inDays} jours';
  }
}

class _Reparations extends StatelessWidget {
  const _Reparations({required this.pannes});

  final List<PanneEntretien> pannes;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final mois = DateTime.now().toUtc().subtract(const Duration(days: 30));
    final signalees = pannes.where(
      (m) => m.signaleLe != null && m.signaleLe!.isAfter(mois),
    );
    final reglees = [
      for (final m in pannes)
        if (m.regleeLe != null && m.regleeLe!.isAfter(mois)) m,
    ];
    final cout = reglees.fold(0, (s, m) => s + m.cout);
    final delai = delaiMoyen(reglees);
    Widget ligne(String libelle, String valeur) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: Text(
              libelle,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 14.5,
                color: p.textSecondary,
              ),
            ),
          ),
          Text(
            valeur,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: p.text,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
    return CarteSection(
      titre: 'Réparations sur 30 jours',
      icone: PhosphorIconsLight.toolbox,
      child: Column(
        children: [
          ligne('Pannes signalées', '${signalees.length}'),
          Divider(height: 1, color: p.border),
          ligne('Pannes réglées', '${reglees.length}'),
          Divider(height: 1, color: p.border),
          ligne('Délai moyen de réparation', delai ?? '—'),
          Divider(height: 1, color: p.border),
          ligne('Coût des réparations', formatAmount(cout)),
        ],
      ),
    );
  }
}

// --- L'activite -----------------------------------------------------------------------

class _Activite extends StatelessWidget {
  const _Activite({required this.taches, required this.pannes});

  final List<TacheMenage> taches;
  final List<PanneEntretien> pannes;

  @override
  Widget build(BuildContext context) {
    final lignes = [
      for (final t in taches) ...entreesDeTache(t),
      for (final m in pannes) ...entreesDePanne(m),
    ]..sort((a, b) => b.moment.compareTo(a.moment));
    return CarteSection(
      titre: 'Dernières activités',
      icone: PhosphorIconsLight.clockCounterClockwise,
      action: LienSection(
        libelle: 'Tout l’historique',
        icone: PhosphorIconsLight.clockCounterClockwise,
        onPressed: () => context.go('/entretien/historique'),
      ),
      child: lignes.isEmpty
          ? const SectionVide('Rien encore sur cette tablette.')
          : Column(
              children: [
                for (final e in lignes.take(6)) LigneHistorique(entree: e),
              ],
            ),
    );
  }
}

/// Une ligne d'une liste du tableau de bord : un repere (la chambre), ce
/// qu'il y a a faire, qui, et un etat en badge.
class _Ligne extends StatelessWidget {
  const _Ligne({
    required this.titre,
    required this.detail,
    this.repere,
    this.etat,
    this.couleurEtat,
    this.alerteDetail = false,
  });

  final String? repere;
  final String titre;
  final String detail;
  final String? etat;
  final Color? couleurEtat;
  final bool alerteDetail;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        children: [
          if (repere != null) ...[
            SizedBox(
              width: 52,
              child: Text(
                repere!,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                  color: p.text,
                  fontFeatures: tabularFigures,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
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
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12.5,
                    color: alerteDetail ? p.warning : p.textSecondary,
                    fontWeight: alerteDetail ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
          if (etat != null) ...[
            const SizedBox(width: 10),
            Tag(etat!, color: couleurEtat),
          ],
        ],
      ),
    );
  }
}
