/// Les finances de l'hotel (demande du 16 octobre, tableau de bord le 18).
///
/// Un clic sur « Finances » ouvre cet ecran ; la fleche du menu deplie la
/// caisse du jour, les factures, les depenses, la comptabilite, les
/// rapports et l'historique des finances.
///
/// Pour la direction et la reception, un tableau de bord sur une periode :
/// le chiffre d'affaires en grand, l'encaisse, ce qui reste a encaisser,
/// les arrhes, les ecarts de caisse ; jour par jour, par moyen de
/// paiement ; du chiffre d'affaires au benefice et les depenses, pour qui
/// lit la comptabilite ; les caisses ouvertes, les ardoises qui doivent de
/// l'argent, les derniers mouvements. Les chiffres sont ceux de l'ecran
/// Rapports, sur la meme periode : un seul calcul.
///
/// Le comptoir garde ses deux tuiles : sa caisse et ses factures.
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
import '../../core/widgets/tuile_metier.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/finances_historique_queries.dart';
import '../../data/local/queries/report_queries.dart';
import '../../data/repositories/cash_repository.dart';
import '../../data/repositories/folio_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../dashboard/dashboard_charts.dart' show Legende;
import '../reports/export/export_model.dart' show formatPointsDeBase;
import '../reports/export/report_sections.dart'
    show libelleCategorie, libelleMoyen;
import '../reports/report_charts.dart';
import '../reports/report_state.dart' show rapportProvider;
import 'finances_presentation.dart';

final _caissesProvider = StreamProvider<List<CashSessionSummary>>(
  (ref) => ref.watch(cashRepositoryProvider).watchSessions(),
);

final _ardoisesOuvertesProvider = StreamProvider<List<FolioSummary>>(
  (ref) =>
      ref.watch(folioRepositoryProvider).watchFolios(status: FolioStatus.OPEN),
);

/// Les mouvements d'argent recents, depuis une heure de bascule (une cle
/// stable dans la journee).
final _encaissementsProvider =
    StreamProvider.family<List<EncaissementHistorique>, DateTime>(
      (ref, depuis) => ref
          .watch(databaseProvider)
          .watchEncaissementsHistorique(depuis: depuis, limite: 8),
    );

final _depensesRecentesProvider =
    StreamProvider.family<List<DepenseHistorique>, DateTime>(
      (ref, depuis) =>
          ref.watch(databaseProvider).watchDepensesHistorique(depuis: depuis),
    );

final _caissesRecentesProvider =
    StreamProvider.family<List<CaisseHistorique>, DateTime>(
      (ref, depuis) =>
          ref.watch(databaseProvider).watchCaissesHistorique(depuis: depuis),
    );

/// Le debut de la semaine ecoulee : sept journees hotelieres.
DateTime _depuisUneSemaine() {
  final j = businessDayFor(DateTime.now()).subtract(const Duration(days: 6));
  return DateTime(j.year, j.month, j.day, heureBasculeParDefaut);
}

/// La periode du tableau de bord.
enum _Periode {
  jour("Aujourd'hui"),
  semaine('7 jours'),
  mois('Ce mois'),
  trente('30 jours');

  const _Periode(this.libelle);
  final String libelle;

  FiltresRapport filtres() {
    final j = businessDayFor(DateTime.now());
    return switch (this) {
      _Periode.jour => FiltresRapport(du: j, au: j),
      _Periode.semaine => FiltresRapport(
        du: DateTime(j.year, j.month, j.day - 6),
        au: j,
      ),
      _Periode.mois => FiltresRapport(du: DateTime(j.year, j.month), au: j),
      _Periode.trente => FiltresRapport(
        du: DateTime(j.year, j.month, j.day - 29),
        au: j,
      ),
    };
  }
}

/// La periode de comparaison, en mots : les Rapports comparent a la meme
/// duree juste avant -- le 18 du mois, aux dix-huit jours d'avant.
String _repere(FiltresRapport f) =>
    f.nbJours == 1 ? 'hier' : 'les ${f.nbJours} jours d’avant';

class _PeriodeNotifier extends Notifier<_Periode> {
  @override
  _Periode build() => _Periode.mois;

  void choisir(_Periode p) => state = p;
}

final _periodeProvider = NotifierProvider<_PeriodeNotifier, _Periode>(
  _PeriodeNotifier.new,
);

class FinancesScreen extends ConsumerWidget {
  const FinancesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acces = ref.watch(sessionProvider).acces;
    // Les memes droits que les entrees du menu qu'elles ouvrent.
    final hotel = acces.peut('folio.read');
    final compta = acces.peut('accounting.read');
    if (!hotel && !compta) return const _Comptoir();
    return _TableauFinances(hotel: hotel, compta: compta);
  }
}

/// Le comptoir : sa caisse et ses factures, rien de l'argent de l'hotel.
class _Comptoir extends ConsumerWidget {
  const _Comptoir();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final acces = session.acces;
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final tuiles = [
      if (acces.peut('cash.session')) _maCaisse(context, ref, session),
      if (acces.peut('order.read'))
        TuileMetier(
          titre: 'Mes factures',
          icone: PhosphorIconsLight.receipt,
          phrase: 'Les ventes payées du comptoir et leurs tickets.',
          chiffres: const [],
          bouton: 'Ouvrir mes factures',
          onOuvrir: () => context.go('/mes-factures'),
          etiree: false,
        ),
    ];
    return ModuleScaffold(
      title: 'Finances',
      subtitle: 'Votre caisse et vos factures',
      body: ListView(
        padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
        children: [
          for (var i = 0; i < tuiles.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            FadeUp(index: i, child: tuiles[i]),
          ],
        ],
      ),
    );
  }

  Widget _maCaisse(
    BuildContext context,
    WidgetRef ref,
    SessionState session,
  ) {
    final tiroirs = ref.watch(_caissesProvider).value;
    final ouverte = tiroirs
        ?.where(
          (c) =>
              c.session.userId == session.agent?.id &&
              c.session.status == CashSessionStatus.OPEN,
        )
        .firstOrNull;
    final depuis = ouverte?.session.openedAt?.toLocal();
    return TuileMetier(
      titre: 'Ma caisse',
      icone: PhosphorIconsLight.cashRegister,
      phrase: tiroirs == null
          ? '…'
          : ouverte == null
          ? 'Aucune caisse ouverte.'
          : depuis == null
          ? 'Votre caisse est ouverte.'
          : 'Votre caisse est ouverte depuis '
                '${depuis.hour.toString().padLeft(2, '0')} h '
                '${depuis.minute.toString().padLeft(2, '0')}.',
      chiffres: const [],
      bouton: 'Ouvrir ma caisse',
      onOuvrir: () => context.go('/ma-caisse'),
      etiree: false,
    );
  }
}

// --- Le tableau de bord ------------------------------------------------------------

class _TableauFinances extends ConsumerWidget {
  const _TableauFinances({required this.hotel, required this.compta});

  /// Lit l'argent de l'hotel : caisses, ardoises, encaissements.
  final bool hotel;

  /// Lit la comptabilite : depenses et benefice.
  final bool compta;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periode = ref.watch(_periodeProvider);
    final filtres = periode.filtres();
    final rapport = ref.watch(rapportProvider(filtres));
    // La courbe et les colonnes : au moins une semaine, un jour seul ne
    // dessine rien.
    final semaine = _Periode.semaine.filtres();
    final trace = filtres.nbJours >= 7
        ? rapport
        : ref.watch(rapportProvider(semaine));
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    return ModuleScaffold(
      title: 'Finances',
      subtitle: compta && !hotel
          ? 'Les dépenses et le bénéfice'
          : 'La caisse, les factures et les comptes',
      action: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          PillButton(
            label: 'Historique',
            icon: PhosphorIconsLight.clockCounterClockwise,
            tone: PillTone.quiet,
            onPressed: () => context.go('/finances/historique'),
          ),
          if (hotel)
            PillButton(
              label: 'Rapports',
              icon: PhosphorIconsLight.chartLineUp,
              tone: PillTone.accent,
              onPressed: () => context.go('/rapports'),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
            child: FilterPills<_Periode>(
              selected: periode,
              onChanged: ref.read(_periodeProvider.notifier).choisir,
              options: [
                for (final p in _Periode.values) FilterOption(p, p.libelle),
              ],
            ),
          ),
          Expanded(
            child: switch (rapport) {
              AsyncData(:final value) => TableauAnime(
                cle: periode,
                builder: (context, traceAnim, barres) => ListView(
                  padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
                  children: [
                    _Bandeau(
                      r: value,
                      courbe: trace.value,
                      periode: periode,
                      hotel: hotel,
                      compta: compta,
                      progres: traceAnim,
                    ),
                    if (hotel) ...[
                      const SizedBox(height: 16),
                      DeuxColonnes(
                        flexGauche: 3,
                        flexDroite: 2,
                        gauche: _ParJour(r: trace.value, progres: barres),
                        droite: _ParMoyen(r: value, progres: barres),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (compta)
                      DeuxColonnes(
                        flexGauche: 3,
                        flexDroite: 2,
                        gauche: _Cascade(r: value, progres: barres),
                        droite: _Depenses(r: value, progres: barres),
                      )
                    else
                      _ParCategorie(r: value, progres: barres),
                    if (hotel) ...[
                      const SizedBox(height: 16),
                      DeuxColonnes(
                        gauche: _Caisses(r: value),
                        droite: const _AEncaisser(),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _Derniers(hotel: hotel, compta: compta),
                  ],
                ),
              ),
              AsyncError(:final error) => EmptyState(
                icon: PhosphorIconsLight.warningCircle,
                title: 'Lecture impossible',
                message: '$error',
              ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }
}

class _Bandeau extends StatelessWidget {
  const _Bandeau({
    required this.r,
    required this.courbe,
    required this.periode,
    required this.hotel,
    required this.compta,
    required this.progres,
  });

  final RapportFinancier r;
  final RapportFinancier? courbe;
  final _Periode periode;
  final bool hotel;
  final bool compta;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final b = r.benefice;
    final ecart = r.ecartCaisse;
    // Pour la comptabilite seule, le chiffre qui compte est le benefice.
    final heroBenefice = compta && !hotel;
    return BandeauChiffres(
      libelle: heroBenefice
          ? 'Bénéfice, ${periode.libelle.toLowerCase()}'
          : 'Chiffre d’affaires, ${periode.libelle.toLowerCase()}',
      valeur: formatAmount(heroBenefice ? b.benefice : r.cles.chiffreAffaires),
      variation: heroBenefice
          ? variationEnPourcent(b.benefice, r.beneficePrecedent)
          : variationEnPourcent(
              r.cles.chiffreAffaires,
              r.precedent.chiffreAffaires,
            ),
      repere: _repere(r.filtres),
      courbe: heroBenefice
          ? null
          : [for (final j in courbe?.parJour ?? const <JourneeFinanciere>[]) j.chiffreAffaires],
      descriptionCourbe: 'Chiffre d’affaires jour par jour',
      progres: progres,
      mesures: [
        if (hotel) ...[
          Mesure(
            'Encaissé',
            formatAmount(r.cles.encaisse),
            aide: '${r.nbEncaissements} encaissement'
                '${r.nbEncaissements > 1 ? 's' : ''}',
            onTap: () => context.go('/caisse'),
          ),
          Mesure(
            'À encaisser',
            formatAmount(r.creances),
            aide: 'Ardoises ouvertes, à date',
            onTap: () => context.go('/factures'),
          ),
          Mesure(
            'Arrhes détenues',
            formatAmount(r.arrhesDetenues),
            aide: 'Clients pas encore arrivés',
          ),
          Mesure(
            'Écart de caisse',
            ecart == 0 ? '0' : _signe(ecart),
            aide: '${r.sessionsCloses} caisse${r.sessionsCloses > 1 ? 's' : ''} '
                'fermée${r.sessionsCloses > 1 ? 's' : ''}',
            alerte: ecart != 0,
          ),
        ],
        if (compta) ...[
          Mesure(
            'Dépenses',
            formatAmount(b.totalDepenses),
            aide: 'Hors stock',
            onTap: () => context.go('/depenses'),
          ),
          if (heroBenefice)
            Mesure('Recettes', formatAmount(b.recettes))
          else
            Mesure(
              'Bénéfice',
              formatAmount(b.benefice),
              aide: b.recettes == 0
                  ? null
                  : '${formatPointsDeBase(b.tauxBp)} des recettes',
              alerte: b.benefice < 0,
              onTap: () => context.go('/comptabilite'),
            ),
        ],
      ],
    );
  }
}

class _ParJour extends StatelessWidget {
  const _ParJour({required this.r, required this.progres});

  final RapportFinancier? r;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final jours = r?.parJour ?? const <JourneeFinanciere>[];
    final ca = [for (final j in jours) j.chiffreAffaires];
    final encaisse = [for (final j in jours) j.encaisse];
    final rien = ca.every((v) => v == 0) && encaisse.every((v) => v == 0);
    return CarteSection(
      centrer: true,
      titre: 'Jour par jour',
      icone: PhosphorIconsLight.chartBar,
      description: 'Ce qui a été vendu, et ce qui est entré en caisse.',
      child: jours.isEmpty || rien
          ? const SectionVide('Rien de vendu ni d’encaissé sur ces journées.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 16,
                  children: [
                    Legende(
                      couleur: AtriumChartColors.parts[0],
                      libelle: 'Chiffre d’affaires',
                    ),
                    Legende(
                      couleur: AtriumChartColors.parts[2],
                      libelle: 'Encaissé',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 210,
                  child: ColonnesRapport(
                    progres: progres,
                    series: [
                      SerieCourbe(
                        'Chiffre d’affaires',
                        ca,
                        AtriumChartColors.parts[0],
                      ),
                      SerieCourbe('Encaissé', encaisse, AtriumChartColors.parts[2]),
                    ],
                    lire: (i) =>
                        '${formatWeekdayShort(jours[i].jour)} '
                        '${formatDayMonth(jours[i].jour)} : '
                        '${formatAmount(ca[i])} vendus, '
                        '${formatAmount(encaisse[i])} encaissés',
                    description: 'Chiffre d’affaires et encaissements',
                    etiquetteDebut: formatDayMonth(jours.first.jour),
                    etiquetteFin: formatDayMonth(jours.last.jour),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Les parts dans un ordre fixe : la couleur suit l'entite, comme dans les
/// Rapports. Le reste va dans « Autres ».
List<PartAnneau> _partsFixes(
  List<Part> parts,
  List<String> ordre,
  String Function(String) libelle,
) => [
  for (var i = 0; i < ordre.length; i++)
    for (final x in parts)
      if (x.cle == ordre[i] && x.montant > 0)
        PartAnneau(libelle(x.cle), x.montant, AtriumChartColors.parts[i]),
  if (parts.any((x) => !ordre.contains(x.cle) && x.montant > 0))
    PartAnneau(
      'Autres',
      parts
          .where((x) => !ordre.contains(x.cle))
          .fold(0, (s, x) => s + x.montant),
      AtriumChartColors.other,
    ),
];

class _ParMoyen extends StatelessWidget {
  const _ParMoyen({required this.r, required this.progres});

  final RapportFinancier r;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) => CarteSection(
    centrer: true,
    titre: 'Par moyen de paiement',
    icone: PhosphorIconsLight.chartDonut,
    child: AnneauRapport(
      progres: progres,
      libelleTotal: 'encaissé',
      description: 'Encaissements par moyen de paiement',
      vide: 'Aucun encaissement sur la période.',
      parts: _partsFixes(r.parMoyen, const [
        'CASH',
        'MOBILE_MONEY',
        'CARD',
        'TRANSFER',
        'CITY_LEDGER',
      ], libelleMoyen),
    ),
  );
}

class _ParCategorie extends StatelessWidget {
  const _ParCategorie({required this.r, required this.progres});

  final RapportFinancier r;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) => CarteSection(
    titre: 'Ce qui a été vendu',
    icone: PhosphorIconsLight.chartPieSlice,
    child: BarresParts(
      couleur: AtriumChartColors.current,
      progres: progres,
      vide: 'Aucune vente sur la période.',
      parts: [
        for (final c in r.parCategorie)
          if (c.montant > 0)
            BarrePart(libelleCategorie(c.cle), c.montant, formatAmount(c.montant)),
      ],
    ),
  );
}

class _Cascade extends StatelessWidget {
  const _Cascade({required this.r, required this.progres});

  final RapportFinancier r;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final b = r.benefice;
    final pas = [
      PasCascade('Recettes', b.recettes, total: true),
      PasCascade('Coût des ventes', b.coutDesVentes),
      PasCascade('Utilisé sans être vendu', b.consommations),
      PasCascade('Pertes', b.pertes),
      PasCascade('Dépenses', b.totalDepenses),
      PasCascade('Bénéfice', b.benefice, total: true),
    ];
    return CarteSection(
      centrer: true,
      titre: 'Du chiffre d’affaires au bénéfice',
      icone: PhosphorIconsLight.chartLineUp,
      description: b.coutsArretesAu == null
          ? 'Les coûts du stock ne sont pas encore arrivés du serveur : le '
                'bénéfice ne retranche que les dépenses.'
          : 'Ce que chaque coût retire des recettes.',
      action: LienSection(
        libelle: 'Comptabilité',
        onPressed: () => context.go('/comptabilite'),
      ),
      child: SizedBox(
        height: 240,
        child: CascadeRapport(
          pas: pas,
          progres: progres,
          lire: (i) => i == 0
              ? 'Recettes : ${formatAmount(pas[i].valeur)}'
              : '${pas[i].libelle} : '
                    '${formatAmount(pas[i].total ? pas[i].valeur : -pas[i].valeur)}',
          description: 'Des recettes au bénéfice, coût par coût',
        ),
      ),
    );
  }
}

class _Depenses extends StatelessWidget {
  const _Depenses({required this.r, required this.progres});

  final RapportFinancier r;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final b = r.benefice;
    return CarteSection(
      centrer: true,
      titre: 'Dépenses par rubrique',
      icone: PhosphorIconsLight.wallet,
      action: LienSection(
        libelle: 'Dépenses',
        onPressed: () => context.go('/depenses'),
      ),
      child: BarresParts(
        couleur: AtriumChartColors.negatif,
        progres: progres,
        vide: 'Aucune dépense saisie sur la période.',
        parts: [
          for (final d in b.depenses.take(6))
            BarrePart(
              d.libelle,
              d.montant,
              formatAmount(d.montant),
              detail: b.totalDepenses == 0
                  ? null
                  : '${(d.montant * 100 / b.totalDepenses).round()} %',
            ),
        ],
      ),
    );
  }
}

class _Caisses extends ConsumerWidget {
  const _Caisses({required this.r});

  final RapportFinancier r;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final caisses =
        ref.watch(_caissesRecentesProvider(_depuisUneSemaine())).value ??
        const <CaisseHistorique>[];
    final ouvertes = [
      for (final c in caisses)
        if (c.fermeeLe == null) c,
    ];
    final aRecevoir = [
      for (final c in caisses)
        if (c.pointDeVente != null && c.fermeeLe != null && c.recuLe == null) c,
    ];
    final doux = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 12.5,
      color: p.textSecondary,
      fontFeatures: tabularFigures,
    );
    Widget ligne(String titre, String detail, String? montant) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
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
                Text(detail, maxLines: 2, style: doux),
              ],
            ),
          ),
          if (montant != null)
            Text(
              montant,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: p.text,
                fontFeatures: tabularFigures,
              ),
            ),
        ],
      ),
    );
    String heure(DateTime d) {
      final l = d.toLocal();
      return '${l.hour} h ${l.minute.toString().padLeft(2, '0')}';
    }

    return CarteSection(
      titre: 'Caisses',
      icone: PhosphorIconsLight.cashRegister,
      action: LienSection(
        libelle: 'Caisse du jour',
        onPressed: () => context.go('/caisse'),
      ),
      child: ouvertes.isEmpty && aRecevoir.isEmpty
          ? const SectionVide('Aucune caisse ouverte, aucun versement attendu.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final c in ouvertes)
                  ligne(
                    c.pointDeVente ?? 'Réception',
                    [
                      'Ouverte${c.ouverteLe == null ? '' : ' depuis ${heure(c.ouverteLe!)}'}',
                      if (c.agent != null) 'par ${c.agent}',
                    ].join(', '),
                    'fond ${formatAmount(c.fond)}',
                  ),
                if (aRecevoir.isNotEmpty) ...[
                  if (ouvertes.isNotEmpty) Divider(height: 17, color: p.border),
                  for (final c in aRecevoir)
                    ligne(
                      'Versement attendu : ${c.pointDeVente}',
                      [
                        if (c.agent != null) 'versé par ${c.agent}',
                        'pas encore reçu par la réception',
                      ].join(', '),
                      c.compte == null ? null : formatAmount(c.compte!),
                    ),
                ],
              ],
            ),
    );
  }
}

class _AEncaisser extends ConsumerWidget {
  const _AEncaisser();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final dues = [
      for (final f
          in ref.watch(_ardoisesOuvertesProvider).value ??
              const <FolioSummary>[])
        if (f.balance > 0) f,
    ]..sort((a, b) => b.balance.compareTo(a.balance));
    final total = dues.fold(0, (s, f) => s + f.balance);
    return CarteSection(
      titre: 'À encaisser',
      icone: PhosphorIconsLight.receipt,
      description: dues.isEmpty
          ? null
          : '${formatAmount(total)} sur ${dues.length} ardoise'
                '${dues.length > 1 ? 's' : ''} ouverte${dues.length > 1 ? 's' : ''}.',
      action: LienSection(
        libelle: 'Factures',
        onPressed: () => context.go('/factures'),
      ),
      child: dues.isEmpty
          ? const SectionVide('Aucune ardoise ouverte ne doit d’argent.')
          : Column(
              children: [
                for (final (i, f) in dues.take(6).indexed) ...[
                  if (i > 0) Divider(height: 1, color: p.border),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                f.guestName,
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
                                f.roomNumber == null
                                    ? 'Ardoise ${f.number}'
                                    : 'Chambre ${f.roomNumber}, ardoise ${f.number}',
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
                        Text(
                          formatAmount(f.balance),
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: p.text,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _Derniers extends ConsumerWidget {
  const _Derniers({required this.hotel, required this.compta});

  final bool hotel;
  final bool compta;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final depuis = _depuisUneSemaine();
    final lignes = [
      if (hotel)
        for (final e
            in ref.watch(_encaissementsProvider(depuis)).value ??
                const <EncaissementHistorique>[])
          ligneDEncaissement(e).$1,
      if (compta)
        for (final d
            in ref.watch(_depensesRecentesProvider(depuis)).value ??
                const <DepenseHistorique>[])
          ligneDeDepense(d).$1,
      if (hotel)
        for (final c
            in ref.watch(_caissesRecentesProvider(depuis)).value ??
                const <CaisseHistorique>[])
          for (final l in lignesDeCaisse(c)) l.$1,
    ]..sort((a, b) => b.moment.compareTo(a.moment));
    return CarteSection(
      titre: 'Derniers mouvements d’argent',
      icone: PhosphorIconsLight.clockCounterClockwise,
      action: LienSection(
        libelle: 'Tout l’historique',
        icone: PhosphorIconsLight.clockCounterClockwise,
        onPressed: () => context.go('/finances/historique'),
      ),
      child: lignes.isEmpty
          ? const SectionVide('Aucun mouvement cette semaine.')
          : Column(
              children: [
                for (final e in lignes.take(6)) LigneHistorique(entree: e),
              ],
            ),
    );
  }
}

String _signe(int montant) =>
    '${montant > 0 ? '+' : '−'}${formatAmount(montant.abs())}';
