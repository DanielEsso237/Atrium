/// L'historique de l'entretien (demande du 18 octobre) : chaque chambre a
/// faire, commencee, faite et controlee ; chaque panne signalee, prise en
/// main, reglee et close -- par journee hoteliere, le plus recent en haut.
///
/// Chacun ne voit que son metier : le menage pour qui lit le menage, les
/// pannes pour qui lit la maintenance.
///
/// Les taches et les pannes ne descendent pas du serveur : l'historique
/// montre ce que cette tablette a enregistre.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/recherche.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/historique.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../core/widgets/tableau_de_bord.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/entretien_queries.dart';
import '../auth/session.dart';
import 'entretien_presentation.dart';

final _tachesProvider =
    StreamProvider.family<List<TacheMenage>, PeriodeHistorique>((ref, p) {
      final debut = p.depuis;
      return ref
          .watch(databaseProvider)
          .watchTachesMenage(
            depuis: debut == null ? null : formatIsoDate(debut),
          );
    });

final _pannesProvider =
    StreamProvider.family<List<PanneEntretien>, PeriodeHistorique>(
      (ref, p) => ref.watch(databaseProvider).watchPannes(depuis: p.depuis),
    );

enum _Genre {
  tout('Tout'),
  menage('Ménage'),
  pannes('Pannes'),
  urgent('Urgent'),
  enCours('Encore ouvert');

  const _Genre(this.libelle);
  final String libelle;

  bool garde(_Ligne l) => switch (this) {
    _Genre.tout => true,
    _Genre.menage => l.tache != null,
    _Genre.pannes => l.panne != null,
    _Genre.urgent =>
      (l.panne?.urgente ?? false) ||
          l.tache?.priorite == Priority.URGENT ||
          l.tache?.priorite == Priority.HIGH,
    _Genre.enCours => (l.panne?.ouverte ?? false) || (l.tache?.aFaire ?? false),
  };
}

class _Ligne {
  const _Ligne(this.entree, {this.tache, this.panne});

  final EntreeHistorique entree;
  final TacheMenage? tache;
  final PanneEntretien? panne;
}

class HistoriqueEntretienScreen extends ConsumerStatefulWidget {
  const HistoriqueEntretienScreen({super.key});

  @override
  ConsumerState<HistoriqueEntretienScreen> createState() =>
      _HistoriqueEntretienScreenState();
}

class _HistoriqueEntretienScreenState
    extends ConsumerState<HistoriqueEntretienScreen> {
  var _periode = PeriodeHistorique.semaine;
  var _genre = _Genre.tout;
  var _recherche = '';

  @override
  Widget build(BuildContext context) {
    final acces = ref.watch(sessionProvider).acces;
    final menage = acces.peut('housekeeping.read');
    final maintenance = acces.peut('maintenance.read');
    final taches = menage
        ? ref.watch(_tachesProvider(_periode))
        : const AsyncData(<TacheMenage>[]);
    final pannes = maintenance
        ? ref.watch(_pannesProvider(_periode))
        : const AsyncData(<PanneEntretien>[]);
    final debut = _periode.depuis;
    bool dansLaPeriode(EntreeHistorique e) =>
        debut == null || !e.moment.toLocal().isBefore(debut);

    final lignes = [
      for (final t in taches.value ?? const <TacheMenage>[])
        for (final e in entreesDeTache(t))
          if (dansLaPeriode(e)) _Ligne(e, tache: t),
      for (final m in pannes.value ?? const <PanneEntretien>[])
        for (final e in entreesDePanne(m))
          if (dansLaPeriode(e)) _Ligne(e, panne: m),
    ]..sort((a, b) => b.entree.moment.compareTo(a.entree.moment));

    final r = Recherche(_recherche);
    final trouvees = [
      for (final l in lignes)
        if (r.garde([l.entree.titre, l.entree.detail, l.entree.etat])) l,
    ];
    final genres = [
      _Genre.tout,
      if (menage && maintenance) ...[_Genre.menage, _Genre.pannes],
      _Genre.urgent,
      _Genre.enCours,
    ];
    final genre = genres.contains(_genre) ? _genre : _Genre.tout;
    int compte(_Genre g) => trouvees.where(g.garde).length;
    final montrees = [
      for (final l in trouvees)
        if (genre.garde(l)) l,
    ];

    // Les totaux de la periode, sur les taches et pannes retenues.
    final faites = {
      for (final l in trouvees)
        if (l.tache != null && l.entree.id.endsWith('|fait')) l.tache!.id: l.tache!,
    }.values;
    final durees = [
      for (final t in faites)
        if (t.duree != null) t.duree!,
    ];
    final signalees = {
      for (final l in trouvees)
        if (l.panne != null && l.entree.id.endsWith('|signalee')) l.panne!.id,
    }.length;
    final reglees = {
      for (final l in trouvees)
        if (l.panne != null && l.entree.id.endsWith('|reglee'))
          l.panne!.id: l.panne!,
    }.values;
    final cout = reglees.fold(0, (s, m) => s + m.cout);

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    return ModuleScaffold(
      title: 'Historique de l’entretien',
      subtitle: menage && maintenance
          ? 'Le ménage et les pannes, dans l’ordre'
          : menage
          ? 'Le ménage, dans l’ordre'
          : 'Les pannes, dans l’ordre',
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
                FiltrePeriode(
                  periode: _periode,
                  onChanged: (p) => setState(() => _periode = p),
                ),
                SizedBox(
                  width: etroit ? double.infinity : 300,
                  child: SearchPill(
                    hint: 'Chambre, panne, agent…',
                    onChanged: (v) => setState(() => _recherche = v),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: (taches.isLoading || pannes.isLoading) && lignes.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ChronologieHistorique(
                    padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
                    entrees: [for (final l in montrees) l.entree],
                    resumeJour: (duJour) => _resume(duJour),
                    entete: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        RecapChiffres(
                          mesures: [
                            if (menage) ...[
                              Mesure(
                                'Chambres faites',
                                '${faites.length}',
                                aide: _periode.libelle,
                              ),
                              Mesure(
                                'Durée moyenne',
                                durees.isEmpty
                                    ? '—'
                                    : duree(
                                        (durees.fold(0, (s, d) => s + d) /
                                                durees.length)
                                            .round(),
                                      ),
                                aide: 'Par chambre',
                              ),
                            ],
                            if (maintenance) ...[
                              Mesure('Pannes signalées', '$signalees'),
                              Mesure(
                                'Pannes réglées',
                                '${reglees.length}',
                                aide: delaiMoyen(reglees) == null
                                    ? null
                                    : 'En ${delaiMoyen(reglees)} en moyenne',
                              ),
                              Mesure('Coût des réparations', formatAmount(cout)),
                            ],
                          ],
                        ),
                        const SizedBox(height: 14),
                        FilterPills<_Genre>(
                          selected: genre,
                          onChanged: (g) => setState(() => _genre = g),
                          options: [
                            for (final g in genres)
                              FilterOption(g, g.libelle, count: compte(g)),
                          ],
                        ),
                        const SizedBox(height: 18),
                      ],
                    ),
                    vide: EmptyState(
                      icon: PhosphorIconsLight.clockCounterClockwise,
                      title: 'Rien à montrer',
                      message: r.vide
                          ? 'Rien sur cette période. Élargissez la période '
                                'ou retirez un filtre.'
                          : '« $_recherche » ne correspond à aucune ligne.',
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// « 6 chambres faites, 1 panne réglée ».
  static String _resume(List<EntreeHistorique> duJour) {
    int n(String fin) => duJour.where((e) => e.id.endsWith(fin)).length;
    final faites = n('|fait');
    final signalees = n('|signalee');
    final reglees = n('|reglee');
    return [
      if (faites > 0) '$faites chambre${faites > 1 ? 's' : ''} faite${faites > 1 ? 's' : ''}',
      if (signalees > 0)
        '$signalees panne${signalees > 1 ? 's' : ''} signalée${signalees > 1 ? 's' : ''}',
      if (reglees > 0)
        '$reglees panne${reglees > 1 ? 's' : ''} réglée${reglees > 1 ? 's' : ''}',
    ].join(', ');
  }
}
