/// L'historique des ventes (demande du 18 octobre) : tout ce qui s'est vendu
/// aux points de vente et aux services, et ce qu'est devenu l'argent.
///
/// Deux sortes de lignes, rangees par journee hoteliere, la plus recente en
/// haut :
///
/// - **les ventes** -- une ardoise servie a un comptoir dans la journee : a
///   qui, quoi, par qui, et ou en est l'argent (payee, a payer, portee sur
///   la chambre) ;
/// - **les tiroirs** -- ouverts avec leur fond, verses le soir, recus par la
///   reception, avec l'ecart s'il y en a un.
///
/// Le perimetre est celui de l'ecran Ventes : le barman ne voit que son bar,
/// la direction tout l'hotel, avec un menu pour n'en regarder qu'un.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/recherche.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/choix_en_menu.dart';
import '../../core/widgets/historique.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../core/widgets/tableau_de_bord.dart';
import '../../data/local/database.dart' show OutletRow;
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/historique_pdv_queries.dart'
    show EtatVentePdv;
import '../../data/local/queries/ventes_historique_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import 'outlet_dashboard_screen.dart' show entreeDeVente;

/// Les points de vente (ids joints par une virgule) et la periode.
typedef _Cle = (String, PeriodeHistorique);

final _ventesProvider = StreamProvider.family<List<VenteHistorique>, _Cle>(
  (ref, cle) => ref
      .watch(databaseProvider)
      .watchHistoriqueVentes(
        pointsDeVente: cle.$1.isEmpty ? const [] : cle.$1.split(','),
        depuis: cle.$2.depuis,
      ),
);

final _tiroirsProvider = StreamProvider.family<List<TiroirHistorique>, _Cle>(
  (ref, cle) => ref
      .watch(databaseProvider)
      .watchHistoriqueTiroirs(
        pointsDeVente: cle.$1.isEmpty ? const [] : cle.$1.split(','),
        depuis: cle.$2.depuis,
      ),
);

/// Ce que l'on regarde dans la chronologie.
enum _Genre {
  tout('Tout'),
  payees('Payées'),
  aPayer('À payer'),
  enChambre('Sur la chambre'),
  tiroirs('Tiroirs');

  const _Genre(this.libelle);
  final String libelle;

  bool garde(_Ligne l) => switch (this) {
    _Genre.tout => true,
    _Genre.payees => l.vente?.etat == EtatVentePdv.payee,
    _Genre.aPayer => l.vente?.etat == EtatVentePdv.aPayer,
    _Genre.enChambre => l.vente?.etat == EtatVentePdv.enChambre,
    _Genre.tiroirs => l.vente == null,
  };
}

/// Une ligne de la chronologie, et la vente dont elle vient s'il y en a une.
class _Ligne {
  const _Ligne(this.entree, {this.vente, this.pointDeVente});

  final EntreeHistorique entree;
  final VenteHistorique? vente;
  final String? pointDeVente;
}

class HistoriqueVentesScreen extends ConsumerStatefulWidget {
  const HistoriqueVentesScreen({super.key});

  @override
  ConsumerState<HistoriqueVentesScreen> createState() =>
      _HistoriqueVentesScreenState();
}

class _HistoriqueVentesScreenState
    extends ConsumerState<HistoriqueVentesScreen> {
  var _periode = PeriodeHistorique.semaine;
  var _genre = _Genre.tout;
  String? _pointDeVente;
  var _recherche = '';

  @override
  Widget build(BuildContext context) {
    const titre = 'Historique des ventes';
    final session = ref.watch(sessionProvider);
    final agentId = session.agent?.id;
    if (agentId == null) {
      return const ModuleScaffold(title: titre, body: SizedBox.shrink());
    }
    final perimetre = ref.watch(perimetrePdvProvider(agentId)).value;
    if (perimetre == null) {
      return const ModuleScaffold(
        title: titre,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    // Les points de vente et les services que l'agent voit, comme a l'ecran
    // Ventes.
    final points = [
      for (final o in perimetre.pointsDeVente)
        if (session.acces.voitGenre(o.kind.name)) o,
    ];
    final choisi = points.where((o) => o.id == _pointDeVente).firstOrNull;
    final ids = choisi == null ? [for (final o in points) o.id] : [choisi.id];
    final cle = (ids.join(','), _periode);
    final libelles = {for (final o in points) o.id: o.label};

    final ventes = ref.watch(_ventesProvider(cle));
    final tiroirs =
        ref.watch(_tiroirsProvider(cle)).value ?? const <TiroirHistorique>[];
    final lignes = [
      for (final v in ventes.value ?? const <VenteHistorique>[])
        _Ligne(
          entreeDeVente(v, libelles[v.pointDeVente]),
          vente: v,
          pointDeVente: v.pointDeVente,
        ),
      for (final t in tiroirs)
        for (final e in _evenementsDuTiroir(t, libelles[t.pointDeVente]))
          // Un tiroir ouvert avant la periode garde son ouverture hors champ.
          if (_periode.depuis == null ||
              !e.moment.toLocal().isBefore(_periode.depuis!))
            _Ligne(e, pointDeVente: t.pointDeVente),
    ]..sort((a, b) => b.entree.moment.compareTo(a.entree.moment));

    final r = Recherche(_recherche);
    final trouvees = [
      for (final l in lignes)
        if (r.garde([l.entree.titre, l.entree.detail, l.entree.etat])) l,
    ];
    int compte(_Genre g) => trouvees.where(g.garde).length;
    final montrees = [
      for (final l in trouvees)
        if (_genre.garde(l)) l,
    ];

    final lesVentes = [
      for (final l in trouvees)
        if (l.vente != null) l.vente!,
    ];
    final recette = lesVentes.fold(0, (s, v) => s + v.montant);
    int part(EtatVentePdv e) => lesVentes
        .where((v) => v.etat == e)
        .fold(0, (s, v) => s + v.montant);

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    return ModuleScaffold(
      title: titre,
      subtitle: perimetre.rattache
          ? points.map((o) => o.label).join(', ')
          : 'Toutes les ventes de l’hôtel, dans l’ordre',
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
                if (points.length > 1)
                  ChoixEnMenu<String?>(
                    choisi: choisi?.id,
                    onChoisi: (id) => setState(() => _pointDeVente = id),
                    compte: '${points.length} lieux de vente',
                    options: [
                      const OptionMenu(
                        null,
                        'Tous les points de vente',
                        icone: PhosphorIconsLight.squaresFour,
                        genre: 'Points de vente et services',
                      ),
                      for (final o in points) _option(o),
                    ],
                  ),
                FiltrePeriode(
                  periode: _periode,
                  onChanged: (p) => setState(() => _periode = p),
                ),
                SizedBox(
                  width: etroit ? double.infinity : 300,
                  child: SearchPill(
                    hint: 'Client, article, agent…',
                    onChanged: (v) => setState(() => _recherche = v),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ventes.isLoading && lignes.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ChronologieHistorique(
                    padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
                    entrees: [for (final l in montrees) l.entree],
                    resumeJour: (duJour) => _resume(duJour, montrees),
                    entete: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        RecapChiffres(
                          mesures: [
                            Mesure(
                              'Ventes',
                              '${lesVentes.length}',
                              aide: _periode.libelle,
                            ),
                            Mesure('Recette', formatAmount(recette)),
                            Mesure(
                              'Ticket moyen',
                              formatAmount(
                                lesVentes.isEmpty
                                    ? 0
                                    : recette ~/ lesVentes.length,
                              ),
                            ),
                            Mesure(
                              'Payé',
                              formatAmount(part(EtatVentePdv.payee)),
                            ),
                            Mesure(
                              'Reste à payer',
                              formatAmount(part(EtatVentePdv.aPayer)),
                              alerte: part(EtatVentePdv.aPayer) > 0,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        FilterPills<_Genre>(
                          selected: _genre,
                          onChanged: (g) => setState(() => _genre = g),
                          options: [
                            for (final g in _Genre.values)
                              FilterOption(g, g.libelle, count: compte(g)),
                          ],
                        ),
                        const SizedBox(height: 18),
                      ],
                    ),
                    vide: EmptyState(
                      icon: PhosphorIconsLight.clockCounterClockwise,
                      title: 'Aucune vente',
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

  OptionMenu<String?> _option(OutletRow o) => OptionMenu(
    o.id,
    o.label,
    icone: o.kind == OutletKind.SERVICE
        ? PhosphorIconsLight.bell
        : PhosphorIconsLight.storefront,
    genre: o.kind == OutletKind.SERVICE ? 'Service' : 'Point de vente',
  );

  /// « 12 ventes, 145 000 FCFA » : ce que la journee a vendu.
  static String _resume(List<EntreeHistorique> duJour, List<_Ligne> lignes) {
    final ids = {for (final e in duJour) e.id};
    final ventes = [
      for (final l in lignes)
        if (l.vente != null && ids.contains(l.entree.id)) l.vente!,
    ];
    if (ventes.isEmpty) return '';
    final total = ventes.fold(0, (s, v) => s + v.montant);
    return '${ventes.length} vente${ventes.length > 1 ? 's' : ''}, '
        '${formatAmount(total)}';
  }
}

/// Un tiroir en trois temps : ouvert, verse, recu.
List<EntreeHistorique> _evenementsDuTiroir(
  TiroirHistorique t,
  String? pointDeVente,
) {
  final p = AtriumPalette.current;
  final ou = pointDeVente ?? 'Point de vente';
  return [
    if (t.ouvertLe != null)
      EntreeHistorique(
        id: '${t.id}|ouvert',
        moment: t.ouvertLe!,
        icone: PhosphorIconsLight.lockSimpleOpen,
        couleur: p.textSecondary,
        titre: 'Tiroir ouvert',
        detail: [
          ou,
          if (t.agent != null) 'par ${t.agent}',
          'fond ${formatAmount(t.fond)}',
        ].join(', '),
        etat: t.fermeLe == null ? 'Ouvert' : null,
        couleurEtat: p.accent,
      ),
    if (t.fermeLe != null)
      EntreeHistorique(
        id: '${t.id}|verse',
        moment: t.fermeLe!,
        icone: PhosphorIconsLight.cashRegister,
        couleur: p.accent,
        titre: 'Recette versée à la réception',
        detail: [
          ou,
          if (t.agent != null) 'par ${t.agent}',
          'attendu ${formatAmount(t.attendu)}',
          if (t.declare != null && t.declare != t.attendu)
            'écart ${_signe(t.declare! - t.attendu)}',
        ].join(', '),
        montant: t.declare == null ? null : formatAmount(t.declare!),
        etat: t.recuLe == null ? 'En attente' : null,
        couleurEtat: p.warning,
      ),
    if (t.recuLe != null)
      EntreeHistorique(
        id: '${t.id}|recu',
        moment: t.recuLe!,
        icone: PhosphorIconsLight.checkCircle,
        couleur: p.success,
        titre: 'Versement reçu',
        detail: [
          ou,
          if (t.recuPar != null) 'reçu par ${t.recuPar}',
          if (t.recu != null && t.declare != null && t.recu != t.declare)
            'écart ${_signe(t.recu! - t.declare!)}',
        ].join(', '),
        montant: t.recu == null ? null : formatAmount(t.recu!),
      ),
  ];
}

String _signe(int montant) =>
    '${montant > 0 ? '+' : '−'}${formatAmount(montant.abs())}';
