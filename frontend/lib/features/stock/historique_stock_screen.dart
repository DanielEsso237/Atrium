/// L'historique des stocks (demande du 18 octobre) : tout ce qui est entre,
/// sorti, passe d'un magasin a l'autre, perdu ou corrige, et les
/// inventaires -- rangé par journee hoteliere, le plus recent en haut.
///
/// Chaque ligne dit le produit, le geste et le magasin, le motif, qui l'a
/// fait et, pour un transfert, qui l'a valide ou refuse. La quantite porte
/// son signe, vu des magasins regardes : un transfert entre deux magasins
/// regardes ne fait que deplacer.
///
/// Les mouvements ne descendent pas du serveur, hormis les transferts en
/// attente : l'historique montre ce que cette tablette a enregistre.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/recherche.dart';
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
import '../auth/session.dart';
import 'stock_presentation.dart';

typedef _Cle = (String, PeriodeHistorique);

List<String> _ids(String cle) => cle.isEmpty ? const [] : cle.split(',');

final _mouvementsProvider =
    StreamProvider.family<List<MouvementStock>, _Cle>(
      (ref, cle) => ref
          .watch(databaseProvider)
          .watchMouvementsStock(_ids(cle.$1), depuis: cle.$2.depuis),
    );

final _inventairesProvider =
    StreamProvider.family<List<InventaireStock>, String>(
      (ref, cle) =>
          ref.watch(databaseProvider).watchInventairesStock(_ids(cle)),
    );

enum _Genre {
  tout('Tout', null),
  entrees('Entrées', {StockMovementType.IN, StockMovementType.RETURN}),
  sorties('Sorties', {StockMovementType.OUT}),
  transferts('Transferts', {StockMovementType.TRANSFER}),
  pertes('Pertes et ajustements', {
    StockMovementType.LOSS,
    StockMovementType.ADJUSTMENT,
  }),
  inventaires('Inventaires', <StockMovementType>{});

  const _Genre(this.libelle, this.types);
  final String libelle;

  /// `null` : tous ; vide : aucun mouvement, les inventaires seuls.
  final Set<StockMovementType>? types;

  bool garde(_Ligne l) => switch (this) {
    _Genre.tout => true,
    _Genre.inventaires => l.mouvement == null,
    _ => l.mouvement != null && types!.contains(l.mouvement!.type),
  };
}

class _Ligne {
  const _Ligne(this.entree, {this.mouvement});

  final EntreeHistorique entree;
  final MouvementStock? mouvement;
}

class HistoriqueStockScreen extends ConsumerStatefulWidget {
  const HistoriqueStockScreen({super.key});

  @override
  ConsumerState<HistoriqueStockScreen> createState() =>
      _HistoriqueStockScreenState();
}

class _HistoriqueStockScreenState extends ConsumerState<HistoriqueStockScreen> {
  var _periode = PeriodeHistorique.semaine;
  var _genre = _Genre.tout;
  String? _magasin;
  var _recherche = '';

  @override
  Widget build(BuildContext context) {
    const titre = 'Historique des stocks';
    final session = ref.watch(sessionProvider);
    final magasins = ref.watch(stockPlacesProvider(session.agent?.id)).value;
    if (magasins == null) {
      return const ModuleScaffold(
        title: titre,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final choisi = magasins.where((m) => m.id == _magasin).firstOrNull;
    final regardes = {
      for (final m in choisi == null ? magasins : [choisi]) m.id,
    };
    final cle = regardes.join(',');
    final mouvements = ref.watch(_mouvementsProvider((cle, _periode)));
    final debut = _periode.depuis;
    final inventaires = [
      for (final i
          in ref.watch(_inventairesProvider(cle)).value ??
              const <InventaireStock>[])
        for (final e in entreesDInventaire(i))
          if (debut == null || !e.moment.toLocal().isBefore(debut)) e,
    ];

    final lignes = [
      for (final m in mouvements.value ?? const <MouvementStock>[])
        _Ligne(entreeDeMouvement(m, regardes: regardes), mouvement: m),
      for (final e in inventaires) _Ligne(e),
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

    // Les totaux de la periode, en quantites : des unites differentes ne
    // s'additionnent pas en valeur sans prix, mais leur nombre dit l'activite.
    final mvts = [
      for (final l in trouvees)
        if (l.mouvement != null) l.mouvement!,
    ];
    int nombre(bool Function(MouvementStock) f) => mvts.where(f).length;
    final entrees = nombre(
      (m) =>
          m.type == StockMovementType.IN || m.type == StockMovementType.RETURN,
    );
    final sorties = nombre((m) => m.type == StockMovementType.OUT);
    final pertes = nombre((m) => m.type == StockMovementType.LOSS);
    final enAttente = nombre((m) => m.statut == StockMovementStatus.PENDING);
    final livre = mvts
        .where((m) => m.type == StockMovementType.IN)
        .fold(0, (s, m) => s + m.quantite * m.coutUnitaire);

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    return ModuleScaffold(
      title: titre,
      subtitle: choisi?.label ??
          (magasins.length == 1
              ? magasins.single.label
              : 'Tous les magasins, dans l’ordre'),
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
                if (magasins.length > 1)
                  ChoixEnMenu<String?>(
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
                          genre: m.isCentral
                              ? 'Magasin central'
                              : 'Point de vente',
                        ),
                    ],
                  ),
                FiltrePeriode(
                  periode: _periode,
                  onChanged: (p) => setState(() => _periode = p),
                ),
                SizedBox(
                  width: etroit ? double.infinity : 300,
                  child: SearchPill(
                    hint: 'Produit, motif, agent…',
                    onChanged: (v) => setState(() => _recherche = v),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: mouvements.isLoading && lignes.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ChronologieHistorique(
                    padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
                    entrees: [for (final l in montrees) l.entree],
                    resumeJour: (duJour) =>
                        '${duJour.length} mouvement${duJour.length > 1 ? 's' : ''}',
                    entete: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        RecapChiffres(
                          mesures: [
                            Mesure(
                              'Entrées',
                              '$entrees',
                              aide: livre > 0
                                  ? '${formatAmount(livre)} livrés'
                                  : 'Livraisons et retours',
                            ),
                            Mesure('Sorties', '$sorties'),
                            Mesure(
                              'Transferts',
                              '${nombre((m) => m.type == StockMovementType.TRANSFER)}',
                            ),
                            Mesure(
                              'Pertes',
                              '$pertes',
                              aide: 'Casse, péremption, inventaire',
                              alerte: pertes > 0,
                            ),
                            Mesure(
                              'En attente',
                              '$enAttente',
                              aide: 'Transferts à valider',
                              alerte: enAttente > 0,
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
}
