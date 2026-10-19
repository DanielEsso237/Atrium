/// L'historique des finances (demande du 18 octobre) : tout l'argent qui
/// entre et sort, et les pieces qui l'accompagnent, par journee hoteliere,
/// le plus recent en haut.
///
/// - encaissements et remboursements, arrhes, caisses et factures, pour qui
///   lit l'argent de l'hotel (`folio.read`) ;
/// - depenses, pour qui lit la comptabilite (`accounting.read`).
///
/// En tete, les totaux de la periode : encaisse, rembourse, depense, et ce
/// qui reste ; puis des filtres par genre, avec leurs compteurs.
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
import '../../data/local/queries/finances_historique_queries.dart';
import '../auth/session.dart';
import 'finances_presentation.dart';

final _encaissementsProvider =
    StreamProvider.family<List<EncaissementHistorique>, PeriodeHistorique>(
      (ref, p) => ref
          .watch(databaseProvider)
          .watchEncaissementsHistorique(depuis: p.depuis),
    );

final _arrhesProvider =
    StreamProvider.family<List<ArrhesHistorique>, PeriodeHistorique>(
      (ref, p) =>
          ref.watch(databaseProvider).watchArrhesHistorique(depuis: p.depuis),
    );

final _depensesProvider =
    StreamProvider.family<List<DepenseHistorique>, PeriodeHistorique>(
      (ref, p) =>
          ref.watch(databaseProvider).watchDepensesHistorique(depuis: p.depuis),
    );

final _caissesProvider =
    StreamProvider.family<List<CaisseHistorique>, PeriodeHistorique>(
      (ref, p) =>
          ref.watch(databaseProvider).watchCaissesHistorique(depuis: p.depuis),
    );

final _facturesProvider =
    StreamProvider.family<List<FactureHistorique>, PeriodeHistorique>(
      (ref, p) =>
          ref.watch(databaseProvider).watchFacturesHistorique(depuis: p.depuis),
    );

/// Les filtres, dans l'ordre ; chacun garde un ou plusieurs genres.
enum _Filtre {
  tout('Tout', null),
  encaissements('Encaissements', {GenreArgent.encaissement}),
  remboursements('Remboursements', {GenreArgent.remboursement}),
  arrhes('Arrhes', {GenreArgent.arrhes}),
  depenses('Dépenses', {GenreArgent.depense}),
  caisses('Caisses', {GenreArgent.caisse}),
  factures('Factures', {GenreArgent.facture});

  const _Filtre(this.libelle, this.genres);
  final String libelle;
  final Set<GenreArgent>? genres;

  bool garde(LigneArgent l) => genres == null || genres!.contains(l.$2);
}

class HistoriqueFinancesScreen extends ConsumerStatefulWidget {
  const HistoriqueFinancesScreen({super.key});

  @override
  ConsumerState<HistoriqueFinancesScreen> createState() =>
      _HistoriqueFinancesScreenState();
}

class _HistoriqueFinancesScreenState
    extends ConsumerState<HistoriqueFinancesScreen> {
  var _periode = PeriodeHistorique.semaine;
  var _filtre = _Filtre.tout;
  var _recherche = '';

  @override
  Widget build(BuildContext context) {
    final acces = ref.watch(sessionProvider).acces;
    final hotel = acces.peut('folio.read');
    final compta = acces.peut('accounting.read');
    List<T> lire<T>(StreamProvider<List<T>> p) =>
        ref.watch(p).value ?? <T>[];

    final encaissements = hotel
        ? lire(_encaissementsProvider(_periode))
        : const <EncaissementHistorique>[];
    final arrhes = hotel
        ? lire(_arrhesProvider(_periode))
        : const <ArrhesHistorique>[];
    final depenses = compta
        ? lire(_depensesProvider(_periode))
        : const <DepenseHistorique>[];
    final caisses = hotel
        ? lire(_caissesProvider(_periode))
        : const <CaisseHistorique>[];
    final factures = hotel
        ? lire(_facturesProvider(_periode))
        : const <FactureHistorique>[];

    final debut = _periode.depuis;
    final lignes = <LigneArgent>[
      for (final e in encaissements) ligneDEncaissement(e),
      for (final a in arrhes) ligneDArrhes(a),
      for (final d in depenses) ligneDeDepense(d),
      for (final c in caisses) ...lignesDeCaisse(c),
      for (final f in factures) ...lignesDeFacture(f),
    ]
      // Une caisse ouverte avant la periode garde son ouverture hors champ.
      ..removeWhere(
        (l) => debut != null && l.$1.moment.toLocal().isBefore(debut),
      )
      ..sort((a, b) => b.$1.moment.compareTo(a.$1.moment));

    final r = Recherche(_recherche);
    final trouvees = [
      for (final l in lignes)
        if (r.garde([l.$1.titre, l.$1.detail, l.$1.etat, l.$1.montant])) l,
    ];
    final filtres = [
      _Filtre.tout,
      if (hotel) ...[
        _Filtre.encaissements,
        _Filtre.remboursements,
        _Filtre.arrhes,
      ],
      if (compta) _Filtre.depenses,
      if (hotel) ...[_Filtre.caisses, _Filtre.factures],
    ];
    final filtre = filtres.contains(_filtre) ? _filtre : _Filtre.tout;
    int compte(_Filtre f) => trouvees.where(f.garde).length;
    final montrees = [
      for (final l in trouvees)
        if (filtre.garde(l)) l,
    ];

    // Les totaux de la periode, sur ce que la recherche retient.
    final ids = {for (final l in trouvees) l.$1.id};
    final encaisse = encaissements
        .where((e) => !e.remboursement && ids.contains(e.id))
        .fold(0, (s, e) => s + e.montant);
    final rembourse = encaissements
        .where((e) => e.remboursement && ids.contains(e.id))
        .fold(0, (s, e) => s + e.montant);
    final recuArrhes = arrhes
        .where((a) => ids.contains('arrhes|${a.id}'))
        .fold(0, (s, a) => s + a.montant);
    final depense = depenses
        .where((d) => !d.annulee && ids.contains('depense|${d.id}'))
        .fold(0, (s, d) => s + d.montant);
    final ecarts = caisses
        .where(
          (c) =>
              c.fermeeLe != null &&
              (debut == null || !c.fermeeLe!.toLocal().isBefore(debut)),
        )
        .fold(0, (s, c) => s + c.ecart);

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final chargement =
        (hotel && ref.watch(_encaissementsProvider(_periode)).isLoading) &&
        lignes.isEmpty;

    return ModuleScaffold(
      title: 'Historique des finances',
      subtitle: hotel && compta
          ? 'Tout l’argent qui entre et qui sort, dans l’ordre'
          : hotel
          ? 'Encaissements, caisses et factures, dans l’ordre'
          : 'Les dépenses, dans l’ordre',
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
                    hint: 'Client, référence, agent, montant…',
                    onChanged: (v) => setState(() => _recherche = v),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: chargement
                ? const Center(child: CircularProgressIndicator())
                : ChronologieHistorique(
                    padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
                    entrees: [for (final l in montrees) l.$1],
                    resumeJour: (duJour) => _resume(duJour, montrees),
                    entete: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        RecapChiffres(
                          mesures: [
                            if (hotel) ...[
                              Mesure(
                                'Encaissé',
                                formatAmount(encaisse),
                                aide: _periode.libelle,
                              ),
                              Mesure(
                                'Remboursé',
                                formatAmount(rembourse),
                                alerte: rembourse > 0,
                              ),
                              Mesure('Arrhes reçues', formatAmount(recuArrhes)),
                            ],
                            if (compta)
                              Mesure('Dépensé', formatAmount(depense)),
                            if (hotel)
                              Mesure(
                                'Écarts de caisse',
                                ecarts == 0
                                    ? '0'
                                    : '${ecarts > 0 ? '+' : '−'}'
                                          '${formatAmount(ecarts.abs())}',
                                alerte: ecarts != 0,
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        FilterPills<_Filtre>(
                          selected: filtre,
                          onChanged: (f) => setState(() => _filtre = f),
                          options: [
                            for (final f in filtres)
                              FilterOption(f, f.libelle, count: compte(f)),
                          ],
                        ),
                        const SizedBox(height: 18),
                      ],
                    ),
                    vide: EmptyState(
                      icon: PhosphorIconsLight.clockCounterClockwise,
                      title: 'Aucun mouvement',
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

  /// « 120 000 FCFA encaissés, 15 000 FCFA dépensés » : la journee en
  /// argent.
  static String _resume(List<EntreeHistorique> duJour, List<LigneArgent> l) {
    final ids = {for (final e in duJour) e.id};
    final duJourLa = [
      for (final x in l)
        if (ids.contains(x.$1.id)) x,
    ];
    final encaissements = duJourLa
        .where((x) => x.$2 == GenreArgent.encaissement)
        .length;
    // Une depense annulee ne retranche rien : elle ne compte pas.
    final depenses = duJourLa
        .where((x) => x.$2 == GenreArgent.depense && x.$1.negatif)
        .length;
    return [
      if (encaissements > 0)
        '$encaissements encaissement${encaissements > 1 ? 's' : ''}',
      if (depenses > 0) '$depenses dépense${depenses > 1 ? 's' : ''}',
    ].join(', ');
  }
}
