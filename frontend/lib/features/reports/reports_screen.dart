/// Rapports : ce que l'hotel a facture, encaisse, occupe et vendu, sur la
/// periode et les filtres choisis, exportable en PDF et en Excel.
///
/// Le Dashboard dit ou en est la journee ; ici, on regarde une periode et on
/// la rend a quelqu'un -- le gerant, le comptable, le proprietaire. D'ou un
/// bouton d'export sur chaque bloc, et un pour le rapport entier.
///
/// Un seul element fort : le releve de nuit en tete, ou la courbe du chiffre
/// d'affaires se deroule a l'arrivee et a chaque changement de filtre. Le
/// reste est sobre, sur papier.
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
import '../../data/local/queries/report_queries.dart';
import '../billing/charge_labels.dart';
import 'export/export_model.dart';
import 'export/exporter.dart';
import 'export/partage.dart';
import 'export/report_sections.dart';
import '../dashboard/dashboard_charts.dart' show Legende;
import 'report_charts.dart';
import 'report_state.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late final _entree = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  late final _trace = CurvedAnimation(
    parent: _entree,
    curve: const Interval(0, 0.8, curve: atriumSpring),
  );
  late final _barres = CurvedAnimation(
    parent: _entree,
    curve: const Interval(0.25, 1, curve: Curves.easeOutCubic),
  );

  /// Le dernier rapport recu : garde a l'ecran pendant que le suivant se
  /// calcule, plutot qu'un ecran blanc a chaque filtre.
  RapportFinancier? _dernier;
  FiltresRapport? _anime;

  @override
  void dispose() {
    _trace.dispose();
    _barres.dispose();
    _entree.dispose();
    super.dispose();
  }

  /// La courbe se redessine quand de nouveaux chiffres arrivent pour de
  /// nouveaux filtres -- pas quand une vente fait bouger un total.
  void _rejouer(FiltresRapport f) {
    if (_anime == f) return;
    _anime = f;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _entree.value = 1;
      } else {
        _entree.forward(from: 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final etat = ref.watch(etatRapportProvider);
    final async = ref.watch(rapportProvider(etat.filtres));
    final r = async.value ?? _dernier;
    if (async.value case final nouveau?) {
      _dernier = nouveau;
      _rejouer(nouveau.filtres);
    }
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 16.0 : 32.0;

    return ModuleScaffold(
      title: 'Rapports',
      subtitle: libellePeriode(etat.filtres),
      action: r == null ? null : _ExportGlobal(rapport: r),
      body: ListView(
        padding: EdgeInsets.fromLTRB(marge, 8, marge, 40),
        children: [
          const _BarreFiltres(),
          const SizedBox(height: 20),
          if (r == null)
            async.hasError
                ? _Message(
                    "Le rapport n'a pas pu être calculé : ${async.error}.",
                  )
                : const Padding(
                    padding: EdgeInsets.symmetric(vertical: 80),
                    child: Center(child: CircularProgressIndicator()),
                  )
          else
            _Corps(rapport: r, trace: _trace, barres: _barres),
        ],
      ),
    );
  }
}

class _Corps extends StatelessWidget {
  const _Corps({
    required this.rapport,
    required this.trace,
    required this.barres,
  });

  final RapportFinancier rapport;
  final Animation<double> trace;
  final Animation<double> barres;

  @override
  Widget build(BuildContext context) {
    final s = SectionsRapport(rapport);
    return LayoutBuilder(
      builder: (context, c) {
        final large = c.maxWidth >= 980;
        Widget paire(Widget a, Widget b) => large
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: a),
                  const SizedBox(width: 16),
                  Expanded(child: b),
                ],
              )
            : Column(children: [a, const SizedBox(height: 16), b]);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Releve(r: rapport, section: s.synthese, trace: trace),
            const SizedBox(height: 16),
            _GrandLivre(r: rapport, colonnes: large ? 4 : 2),
            const SizedBox(height: 16),
            // Appariees par hauteur : deux blocs courts, puis deux longs,
            // pour qu'aucun ne laisse un trou sous son voisin.
            paire(
              _CarteCategories(r: rapport, section: s.chiffreAffaires,
                  progres: barres),
              _CartePointsDeVente(r: rapport, section: s.pointsDeVente,
                  progres: barres),
            ),
            const SizedBox(height: 16),
            _CarteOccupation(r: rapport, section: s.occupation, trace: trace,
                progres: barres),
            const SizedBox(height: 16),
            _CarteActivite(r: rapport, section: s.activite, trace: trace,
                progres: barres),
            const SizedBox(height: 16),
            paire(
              _CarteEncaissements(r: rapport, section: s.encaissements,
                  progres: barres),
              _CarteStock(r: rapport, section: s.stockEtMarges,
                  progres: barres),
            ),
            const SizedBox(height: 16),
            paire(
              _CarteCaisses(r: rapport, section: s.caisses),
              _CarteMenageMaintenance(r: rapport,
                  section: s.menageEtMaintenance, progres: barres),
            ),
          ],
        );
      },
    );
  }
}

// --- Filtres -------------------------------------------------------------------

class _BarreFiltres extends ConsumerWidget {
  const _BarreFiltres();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final etat = ref.watch(etatRapportProvider);
    final f = etat.filtres;
    final notifier = ref.read(etatRapportProvider.notifier);
    final points = ref.watch(pointsDeVenteRapportProvider).value ?? const [];
    final agents = ref.watch(agentsRapportProvider).value ?? const [];
    final types = ref.watch(typesChambreRapportProvider).value ?? const [];

    String? nom<T>(List<T> l, String? id, String Function(T) cle,
        String Function(T) lire) {
      for (final e in l) {
        if (cle(e) == id) return lire(e);
      }
      return null;
    }

    Future<void> dates() async {
      final aujourdhui = businessDayFor(DateTime.now());
      final choix = await showDateRangePicker(
        context: context,
        firstDate: DateTime(aujourdhui.year - 3),
        lastDate: aujourdhui,
        initialDateRange: DateTimeRange(start: f.du, end: f.au),
        helpText: 'Période du rapport',
        saveText: 'Afficher',
        cancelText: 'Annuler',
      );
      if (choix != null) notifier.choisirDates(choix.start, choix.end);
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Filtre<Periode>(
          icone: PhosphorIconsLight.calendarBlank,
          libelle: etat.periode == Periode.personnalisee
              ? libellePeriode(f)
              : etat.periode.libelle,
          actif: true,
          choix: [
            for (final p in Periode.values)
              (p, p == Periode.personnalisee ? 'Choisir les dates…' : p.libelle),
          ],
          courant: etat.periode,
          surChoix: (p) => p == Periode.personnalisee
              ? dates()
              : notifier.choisirPeriode(p!),
          sansTous: true,
        ),
        _Filtre<String>(
          icone: PhosphorIconsLight.storefront,
          libelle: nom(points, f.pointDeVenteId, (o) => o.id, (o) => o.label) ??
              'Point de vente',
          actif: f.pointDeVenteId != null,
          tous: 'Tous les points de vente',
          choix: [for (final o in points) (o.id, o.label)],
          courant: f.pointDeVenteId,
          surChoix: notifier.pointDeVente,
        ),
        _Filtre<String>(
          icone: PhosphorIconsLight.user,
          libelle: nom(agents, f.agentId, (u) => u.id,
                  (u) => '${u.firstName} ${u.lastName}') ??
              'Agent',
          actif: f.agentId != null,
          tous: 'Tous les agents',
          choix: [
            for (final u in agents) (u.id, '${u.firstName} ${u.lastName}'),
          ],
          courant: f.agentId,
          surChoix: notifier.agent,
        ),
        _Filtre<PaymentMethod>(
          icone: PhosphorIconsLight.creditCard,
          libelle: f.moyen == null
              ? 'Moyen de paiement'
              : paymentMethodLabel(f.moyen!),
          actif: f.moyen != null,
          tous: 'Tous les moyens',
          choix: [
            for (final m in PaymentMethod.values) (m, paymentMethodLabel(m)),
          ],
          courant: f.moyen,
          surChoix: notifier.moyen,
        ),
        _Filtre<String>(
          icone: PhosphorIconsLight.bed,
          libelle: nom(types, f.typeChambreId, (t) => t.id, (t) => t.label) ??
              'Type de chambre',
          actif: f.typeChambreId != null,
          tous: 'Tous les types',
          choix: [for (final t in types) (t.id, t.label)],
          courant: f.typeChambreId,
          surChoix: notifier.typeChambre,
        ),
        if (f.filtre)
          TextButton.icon(
            onPressed: notifier.effacerFiltres,
            icon: const Icon(PhosphorIconsLight.arrowCounterClockwise, size: 18),
            label: const Text('Effacer les filtres'),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 44),
              foregroundColor: AtriumPalette.current.accent,
              textStyle: const TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

/// Un filtre en pilule qui ouvre sa liste. Plein quand il restreint le
/// rapport : on voit d'un coup d'oeil ce qui est filtre.
class _Filtre<T> extends StatelessWidget {
  const _Filtre({
    required this.icone,
    required this.libelle,
    required this.actif,
    required this.choix,
    required this.courant,
    required this.surChoix,
    this.tous = '',
    this.sansTous = false,
  });

  final IconData icone;
  final String libelle;
  final bool actif;
  final List<(T, String)> choix;
  final T? courant;
  final ValueChanged<T?> surChoix;
  final String tous;
  final bool sansTous;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final style = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14,
      fontWeight: actif ? FontWeight.w700 : FontWeight.w500,
      color: actif ? p.accent : p.text,
    );
    MenuItemButton item(T? valeur, String texte) => MenuItemButton(
      onPressed: () => surChoix(valeur),
      trailingIcon: valeur == courant
          ? Icon(PhosphorIconsLight.check, size: 18, color: p.accent)
          : null,
      style: MenuItemButton.styleFrom(minimumSize: const Size(220, 46)),
      child: Text(
        texte,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 14,
          fontWeight: valeur == courant ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );

    return MenuAnchor(
      menuChildren: [
        if (!sansTous) item(null, tous),
        for (final (v, t) in choix) item(v, t),
      ],
      builder: (context, menu, _) => Semantics(
        button: true,
        label: 'Filtre $libelle',
        child: InkWell(
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: AtriumMotion.of(context, AtriumMotion.base),
            curve: AtriumMotion.standard,
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: actif ? p.accentFill : p.paper,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: actif ? p.accentBorder : p.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icone, size: 18, color: actif ? p.accent : p.textSecondary),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    libelle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  PhosphorIconsLight.caretDown,
                  size: 14,
                  color: actif ? p.accent : p.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- Export --------------------------------------------------------------------

/// Le rapport entier, toutes sections, dans le format choisi.
class _ExportGlobal extends ConsumerWidget {
  const _ExportGlobal({required this.rapport});

  final RapportFinancier rapport;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MenuAnchor(
    alignmentOffset: const Offset(0, 6),
    menuChildren: [
      for (final format in FormatExport.values)
        _ItemExport(
          format: format,
          onPressed: () => exporterRapport(
            context: context,
            ref: ref,
            filtres: rapport.filtres,
            titre: 'Rapport financier',
            sections: SectionsRapport(rapport).toutes,
            format: format,
          ),
        ),
    ],
    builder: (context, menu, _) => PillButton(
      label: 'Exporter le rapport',
      icon: PhosphorIconsLight.downloadSimple,
      compact: true,
      onPressed: () => menu.isOpen ? menu.close() : menu.open(),
    ),
  );
}

/// Le bouton d'export d'un bloc.
class _BoutonExport extends ConsumerWidget {
  const _BoutonExport({
    required this.rapport,
    required this.section,
    this.surFonce = false,
  });

  final RapportFinancier rapport;
  final Section section;
  final bool surFonce;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    return MenuAnchor(
      menuChildren: [
        for (final format in FormatExport.values)
          _ItemExport(
            format: format,
            onPressed: () => exporterRapport(
              context: context,
              ref: ref,
              filtres: rapport.filtres,
              titre: section.titre,
              sections: [section],
              format: format,
            ),
          ),
      ],
      builder: (context, menu, _) => IconButton(
        tooltip: 'Exporter « ${section.titre} »',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: Icon(
          PhosphorIconsLight.downloadSimple,
          size: 20,
          color: surFonce ? p.onNight : p.accent,
        ),
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          backgroundColor: surFonce
              ? p.onNight.withValues(alpha: 0.1)
              : p.accentTint,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class _ItemExport extends StatelessWidget {
  const _ItemExport({required this.format, required this.onPressed});

  final FormatExport format;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => MenuItemButton(
    onPressed: onPressed,
    leadingIcon: Icon(
      format == FormatExport.pdf
          ? PhosphorIconsLight.filePdf
          : PhosphorIconsLight.fileXls,
      size: 20,
    ),
    style: MenuItemButton.styleFrom(minimumSize: const Size(240, 48)),
    child: Text(
      format == FormatExport.pdf
          ? 'PDF, prêt à imprimer'
          : 'Excel, pour retravailler les chiffres',
      style: const TextStyle(fontFamily: atriumFontFamily, fontSize: 14),
    ),
  );
}

// --- Le releve -----------------------------------------------------------------

String _texteVariation(int actuel, int precedent, int nbJours) {
  final bp = variationBp(actuel, precedent);
  final (avec, aux) = nbJours == 1
      ? ('avec la veille', 'à la veille')
      : ('avec les $nbJours jours précédents', 'aux $nbJours jours précédents');
  if (bp == null) return 'Rien à comparer $avec';
  if (bp == 0) return 'Stable par rapport $aux';
  return '${bp > 0 ? '+' : ''}${formatPointsDeBase(bp)} par rapport $aux';
}

/// Le bloc de nuit : le chiffre d'affaires, sa tendance et ce qui reste a
/// encaisser. La courbe y occupe toute la largeur.
class _Releve extends StatelessWidget {
  const _Releve({required this.r, required this.section, required this.trace});

  final RapportFinancier r;
  final Section section;
  final Animation<double> trace;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final c = r.cles;
    final bp = variationBp(c.chiffreAffaires, r.precedent.chiffreAffaires);
    final etroit = MediaQuery.sizeOf(context).width < 700;
    const laiton = AtriumPalette.brassOnBlue;

    TextStyle doux(double t, {FontWeight w = FontWeight.w500}) => TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: t,
      fontWeight: w,
      color: p.onNightSoft,
      fontFeatures: tabularFigures,
    );
    TextStyle fort(double t) => TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: t,
      fontWeight: FontWeight.w800,
      letterSpacing: -t * 0.035,
      height: 1.05,
      color: p.onNight,
      fontFeatures: tabularFigures,
    );

    final secondaire = [
      _ChiffreNuit(
        libelle: 'Encaissé',
        valeur: formatAmount(c.encaisse),
        detail: _texteVariation(c.encaisse, r.precedent.encaisse,
            r.filtres.nbJours),
        pastille: laiton,
      ),
      _ChiffreNuit(
        libelle: 'Reste à encaisser',
        valeur: formatAmount(r.creances),
        detail: 'sur les ardoises ouvertes, à ce jour',
      ),
    ];

    return Container(
      padding: EdgeInsets.fromLTRB(etroit ? 18 : 28, 22, etroit ? 14 : 22, 20),
      decoration: BoxDecoration(
        color: p.night,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: p.onNight,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text("Chiffre d'affaires",
                            style: doux(14, w: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatAmount(c.chiffreAffaires),
                        style: fort(etroit ? 32 : 44),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (bp != null && bp != 0) ...[
                          Icon(
                            bp > 0
                                ? PhosphorIconsLight.trendUp
                                : PhosphorIconsLight.trendDown,
                            size: 18,
                            color: bp > 0 ? laiton : p.onNightSoft,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            _texteVariation(c.chiffreAffaires,
                                r.precedent.chiffreAffaires, r.filtres.nbJours),
                            style: doux(13),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!etroit) ...[
                const SizedBox(width: 24),
                SizedBox(
                  width: 250,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      secondaire[0],
                      const SizedBox(height: 14),
                      secondaire[1],
                    ],
                  ),
                ),
              ],
              const SizedBox(width: 12),
              _BoutonExport(rapport: r, section: section, surFonce: true),
            ],
          ),
          if (etroit) ...[
            const SizedBox(height: 16),
            secondaire[0],
            const SizedBox(height: 12),
            secondaire[1],
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: etroit ? 150 : 190,
            child: CourbeRapport(
              surFonce: true,
              progres: trace,
              series: [
                SerieCourbe("Chiffre d'affaires",
                    [for (final j in r.parJour) j.chiffreAffaires], p.onNight),
                SerieCourbe('Encaissé',
                    [for (final j in r.parJour) j.encaisse], laiton),
              ],
              lire: (i) {
                final j = r.parJour[i];
                return '${formatDayMonth(j.jour)} : '
                    '${formatAmount(j.chiffreAffaires)} facturés, '
                    '${formatAmount(j.encaisse)} encaissés';
              },
              description:
                  "Chiffre d'affaires et encaissements jour par jour, "
                  '${libellePeriode(r.filtres).toLowerCase()}',
              etiquetteDebut: formatDayMonth(r.filtres.du),
              etiquetteFin: formatDayMonth(r.filtres.au),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChiffreNuit extends StatelessWidget {
  const _ChiffreNuit({
    required this.libelle,
    required this.valeur,
    required this.detail,
    this.pastille,
  });

  final String libelle;
  final String valeur;
  final String detail;
  final Color? pastille;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (pastille != null) ...[
              Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: pastille, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              libelle,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.onNightSoft,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            valeur,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
              color: p.onNight,
              fontFeatures: tabularFigures,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          detail,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 12,
            color: p.onNightSoft,
          ),
        ),
      ],
    );
  }
}

// --- Le grand livre ------------------------------------------------------------

/// Les chiffres qui completent le releve, sur une seule feuille quadrillee :
/// on les lit comme une ligne de comptes, pas comme huit cartes.
class _GrandLivre extends StatelessWidget {
  const _GrandLivre({required this.r, required this.colonnes});

  final RapportFinancier r;
  final int colonnes;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final c = r.cles;
    final ecartPoints = c.tauxOccupation - r.precedent.tauxOccupation;
    final cases = <(String, String, String, Color?)>[
      (
        "Taux d'occupation",
        '${c.tauxOccupation} %',
        // Une periode precedente sans aucune nuit vendue n'est pas un repere :
        // c'est souvent une tablette qui n'en a rien recu.
        r.precedent.nuitees == 0
            ? '${c.nuitees} nuitées vendues'
            : ecartPoints == 0
            ? 'stable'
            : '${ecartPoints > 0 ? '+' : ''}$ecartPoints point'
                  '${ecartPoints.abs() > 1 ? 's' : ''} sur la période précédente',
        null,
      ),
      (
        'Prix moyen par nuit',
        formatAmount(c.prixMoyen),
        'sur ${c.nuitees} nuitée${c.nuitees > 1 ? 's' : ''}',
        null,
      ),
      ('RevPAR', formatAmount(c.revPar), 'par chambre disponible', null),
      (
        'Marge brute',
        formatAmount(r.margeBrute),
        r.ventesStock == 0
            ? 'aucun article stocké vendu'
            : 'taux de ${formatPointsDeBase(r.tauxMargeBp)}',
        r.margeBrute < 0 ? p.error : null,
      ),
      ('Arrhes détenues', formatAmount(r.arrhesDetenues),
          'dossiers pas encore arrivés', null),
      ('Taxes collectées', formatAmount(r.taxes), 'comprises dans le chiffre',
          null),
      ('Remises accordées', formatAmount(r.remises), 'déjà déduites', null),
      (
        'Écart de caisse',
        formatAmount(r.ecartCaisse),
        libelleCaisses(r.sessionsCloses),
        r.ecartCaisse < 0 ? p.error : null,
      ),
    ];

    final lignes = <TableRow>[];
    for (var i = 0; i < cases.length; i += colonnes) {
      lignes.add(
        TableRow(
          children: [
            for (final (libelle, valeur, detail, couleur)
                in cases.skip(i).take(colonnes))
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      libelle,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: p.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        valeur,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          color: couleur ?? p.text,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      maxLines: 2,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 12,
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

    return Container(
      decoration: BoxDecoration(
        color: p.paper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Table(
        border: TableBorder.symmetric(inside: BorderSide(color: p.border)),
        children: lignes,
      ),
    );
  }
}

// --- Les blocs -----------------------------------------------------------------

/// Le cadre d'un bloc : titre, ce qu'il suit, export, contenu.
class _Bloc extends StatelessWidget {
  const _Bloc({
    required this.rapport,
    required this.section,
    required this.icone,
    required this.child,
  });

  final RapportFinancier rapport;
  final Section section;
  final IconData icone;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(20, 16, 14, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icone, size: 20, color: p.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  section.titre,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: p.text,
                  ),
                ),
              ),
              _BoutonExport(rapport: rapport, section: section),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 2),
            child: Text(
              section.description,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 12.5,
                height: 1.4,
                color: p.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(padding: const EdgeInsets.only(right: 6), child: child),
        ],
      ),
    );
  }
}

/// Des chiffres alignes en tete d'un bloc.
class _Mesures extends StatelessWidget {
  const _Mesures(this.mesures);

  final List<(String, String)> mesures;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Wrap(
      spacing: 28,
      runSpacing: 12,
      children: [
        for (final (libelle, valeur) in mesures)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                libelle,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                valeur,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                  fontFeatures: tabularFigures,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _SousTitre extends StatelessWidget {
  const _SousTitre(this.texte);

  final String texte;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 4),
    child: Text(
      texte,
      style: TextStyle(
        fontFamily: atriumFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: AtriumPalette.current.text,
      ),
    ),
  );
}

String _part(int valeur, int total) =>
    formatPointsDeBase(partBp(valeur, total));

class _CarteCategories extends StatelessWidget {
  const _CarteCategories({
    required this.r,
    required this.section,
    required this.progres,
  });

  final RapportFinancier r;
  final Section section;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final total = r.cles.chiffreAffaires;
    final jours = r.filtres.nbJours;
    return _Bloc(
      rapport: r,
      section: section,
      icone: PhosphorIconsLight.receipt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Mesures([
            ('Moyenne par jour', formatAmount(jours == 0 ? 0 : total ~/ jours)),
            ('Taxes collectées', formatAmount(r.taxes)),
          ]),
          const _SousTitre('Par catégorie'),
          BarresParts(
            couleur: AtriumChartColors.current,
            progres: progres,
            parts: [
              for (final c in r.parCategorie)
                BarrePart(
                  libelleCategorie(c.cle),
                  c.montant,
                  formatAmount(c.montant),
                  detail: _part(c.montant, ventesBrutes(r)),
                ),
            ],
            vide: "Aucune vente sur la période.",
          ),
        ],
      ),
    );
  }
}

class _CarteEncaissements extends StatelessWidget {
  const _CarteEncaissements({
    required this.r,
    required this.section,
    required this.progres,
  });

  final RapportFinancier r;
  final Section section;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final total = r.cles.encaisse;
    return _Bloc(
      rapport: r,
      section: section,
      icone: PhosphorIconsLight.coins,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Mesures([
            ('Opérations', formatNombre(r.nbEncaissements)),
            ('Remboursé', formatAmount(r.rembourse)),
          ]),
          const _SousTitre('Par moyen de paiement'),
          BarresParts(
            couleur: AtriumChartColors.types[1],
            progres: progres,
            parts: [
              for (final m in r.parMoyen)
                BarrePart(
                  libelleMoyen(m.cle),
                  m.montant,
                  formatAmount(m.montant),
                  detail: _part(m.montant, total),
                ),
            ],
            vide: 'Aucun encaissement sur la période.',
          ),
          const _SousTitre('Par agent'),
          BarresParts(
            couleur: AtriumChartColors.types[2],
            progres: progres,
            parts: [
              for (final a in r.parAgent.take(5))
                BarrePart(
                  a.libelle,
                  a.montant,
                  formatAmount(a.montant),
                  detail:
                      '${a.nombre} opération${a.nombre > 1 ? 's' : ''}',
                ),
            ],
            vide: 'Aucun encaissement sur la période.',
          ),
        ],
      ),
    );
  }
}

class _CarteOccupation extends StatelessWidget {
  const _CarteOccupation({
    required this.r,
    required this.section,
    required this.trace,
    required this.progres,
  });

  final RapportFinancier r;
  final Section section;
  final Animation<double> trace;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final c = r.cles;
    final entete = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: p.textSecondary,
    );
    final cellule = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 13.5,
      color: p.text,
      fontFeatures: tabularFigures,
    );

    final courbe = SizedBox(
      height: 200,
      child: CourbeRapport(
        progres: trace,
        series: [
          SerieCourbe("Taux d'occupation",
              [for (final n in r.occupation) n.taux],
              AtriumChartColors.current),
        ],
        lire: (i) {
          final n = r.occupation[i];
          return '${formatDayMonth(n.jour)} : ${n.occupees} chambre'
              '${n.occupees > 1 ? 's' : ''} sur ${n.disponibles}, '
              '${n.taux} %';
        },
        description: "Taux d'occupation nuit par nuit",
        etiquetteDebut: formatDayMonth(r.filtres.du),
        etiquetteFin: formatDayMonth(r.filtres.au),
      ),
    );

    final types = Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1.4),
        3: FlexColumnWidth(1.8),
      },
      border: TableBorder(horizontalInside: BorderSide(color: p.border)),
      children: [
        TableRow(
          children: [
            for (final (t, droite) in [
              ('Type', false),
              ('Nuitées', true),
              ('Taux', true),
              ('Hébergement', true),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(t,
                    textAlign: droite ? TextAlign.right : TextAlign.left,
                    style: entete),
              ),
          ],
        ),
        for (final t in r.parType)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  '${t.libelle} (${t.chambres})',
                  style: cellule.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text('${t.nuitees}',
                    textAlign: TextAlign.right, style: cellule),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text('${t.taux} %',
                    textAlign: TextAlign.right, style: cellule),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(formatAmount(t.chiffreAffaires),
                    textAlign: TextAlign.right, style: cellule),
              ),
            ],
          ),
      ],
    );

    return _Bloc(
      rapport: r,
      section: section,
      icone: PhosphorIconsLight.bed,
      child: LayoutBuilder(
        builder: (context, contraintes) {
          final large = contraintes.maxWidth >= 860;
          final mesures = _Mesures([
            ("Taux d'occupation", '${c.tauxOccupation} %'),
            ('Nuitées vendues', '${c.nuitees} sur ${c.nuiteesDisponibles}'),
            ('Chiffre hébergement', formatAmount(c.chiffreHebergement)),
            ('Prix moyen', formatAmount(c.prixMoyen)),
            ('RevPAR', formatAmount(c.revPar)),
          ]);
          if (!large) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                mesures,
                const SizedBox(height: 18),
                courbe,
                const _SousTitre('Par type de chambre'),
                types,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              mesures,
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: courbe),
                  const SizedBox(width: 28),
                  Expanded(flex: 2, child: types),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CartePointsDeVente extends StatelessWidget {
  const _CartePointsDeVente({
    required this.r,
    required this.section,
    required this.progres,
  });

  final RapportFinancier r;
  final Section section;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final total = r.ventesPointsDeVente;
    final clients = r.pointsDeVente.fold<int>(0, (s, l) => s + l.ventes);
    return _Bloc(
      rapport: r,
      section: section,
      icone: PhosphorIconsLight.storefront,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Mesures([
            ('Ventes', formatAmount(total)),
            ('Clients servis', formatNombre(clients)),
            ('Panier moyen',
                formatAmount(clients == 0 ? 0 : total ~/ clients)),
          ]),
          const SizedBox(height: 10),
          BarresParts(
            couleur: AtriumChartColors.types[2],
            progres: progres,
            parts: [
              for (final l in r.pointsDeVente)
                BarrePart(
                  l.libelle,
                  l.chiffreAffaires,
                  formatAmount(l.chiffreAffaires),
                  detail: '${l.ventes} client${l.ventes > 1 ? 's' : ''}',
                ),
            ],
            vide: 'Aucun point de vente sur cette tablette.',
          ),
        ],
      ),
    );
  }
}

class _CarteStock extends StatelessWidget {
  const _CarteStock({
    required this.r,
    required this.section,
    required this.progres,
  });

  final RapportFinancier r;
  final Section section;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final aRefaire = r.stock.where((s) => s.sousLeSeuil || s.quantite <= 0);
    return _Bloc(
      rapport: r,
      section: section,
      icone: PhosphorIconsLight.archive,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Mesures([
            ('Marge brute', formatAmount(r.margeBrute)),
            ('Taux de marge', formatPointsDeBase(r.tauxMargeBp)),
            ("Stock au prix d'achat", formatAmount(r.valeurStockAchat)),
          ]),
          const _SousTitre('Meilleures marges'),
          BarresParts(
            couleur: AtriumChartColors.types[3],
            progres: progres,
            parts: [
              for (final m in r.marges.take(5))
                BarrePart(
                  m.libelle,
                  m.marge,
                  formatAmount(m.marge),
                  detail: '${m.quantite} vendu${m.quantite > 1 ? 's' : ''}',
                ),
            ],
            vide: 'Aucun article relié au stock vendu sur la période.',
          ),
          const _SousTitre('Mouvements de la période'),
          BarresParts(
            couleur: AtriumChartColors.other,
            progres: progres,
            parts: [
              for (final m in r.gestion.mouvements)
                BarrePart(
                  libelleMouvement(m.type),
                  m.quantite,
                  '${formatNombre(m.quantite)} unités',
                  detail: formatAmount(m.valeur),
                ),
            ],
            vide: 'Aucun mouvement connu de cette tablette.',
          ),
          _SousTitre(
            aRefaire.isEmpty
                ? 'Stock suffisant partout'
                : 'À réapprovisionner (${aRefaire.length})',
          ),
          for (final s in aRefaire.take(5))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.libelle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                  ),
                  Tag(
                    s.quantite <= 0 ? 'Rupture' : '${s.quantite} sur ${s.seuil}',
                    color: s.quantite <= 0 ? p.error : p.warning,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CarteActivite extends StatelessWidget {
  const _CarteActivite({
    required this.r,
    required this.section,
    required this.trace,
    required this.progres,
  });

  final RapportFinancier r;
  final Section section;
  final Animation<double> trace;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final a = r.activite;
    final mesures = _Mesures([
      ('Arrivées', '${a.arrivees} sur ${a.arriveesPrevues} prévues'),
      ('Départs', formatNombre(a.departs)),
      ('Nouvelles réservations', formatNombre(a.nouvelles)),
      ('Annulations', formatNombre(a.annulations)),
      ('Non présentés', formatNombre(a.nonPresentes)),
      ('Personnes accueillies', formatNombre(a.personnes)),
      ('Durée moyenne', '${formatDixiemes(a.dureeMoyenneDixiemes)} nuits'),
    ]);
    final courbe = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 190,
          child: CourbeRapport(
            progres: trace,
            remplir: false,
            series: [
              SerieCourbe('Arrivées', [for (final j in a.parJour) j.$2],
                  AtriumChartColors.arrivals),
              SerieCourbe('Départs', [for (final j in a.parJour) j.$3],
                  AtriumChartColors.departures),
            ],
            lire: (i) {
              final (jour, arr, dep) = a.parJour[i];
              return '${formatDayMonth(jour)} : $arr arrivée${arr > 1 ? 's' : ''}, '
                  '$dep départ${dep > 1 ? 's' : ''}';
            },
            description: 'Arrivées et départs jour par jour',
            etiquetteDebut: formatDayMonth(r.filtres.du),
            etiquetteFin: formatDayMonth(r.filtres.au),
          ),
        ),
        const SizedBox(height: 8),
        const Wrap(
          spacing: 16,
          children: [
            Legende(couleur: AtriumChartColors.arrivals, libelle: 'Arrivées'),
            Legende(couleur: AtriumChartColors.departures, libelle: 'Départs'),
          ],
        ),
      ],
    );
    final origines = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SousTitre('Origine des séjours'),
        BarresParts(
          couleur: AtriumChartColors.types[1],
          progres: progres,
          parts: [
            for (final o in a.parOrigine)
              BarrePart(
                libelleOrigine(o.cle),
                o.montant,
                '${o.montant} séjour${o.montant > 1 ? 's' : ''}',
                detail: _part(o.montant, a.arriveesPrevues),
              ),
          ],
          vide: 'Aucune arrivée prévue sur la période.',
        ),
      ],
    );
    return _Bloc(
      rapport: r,
      section: section,
      icone: PhosphorIconsLight.calendarCheck,
      child: LayoutBuilder(
        builder: (context, c) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            mesures,
            const SizedBox(height: 18),
            if (c.maxWidth >= 860)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: courbe),
                  const SizedBox(width: 28),
                  Expanded(flex: 2, child: origines),
                ],
              )
            else ...[courbe, origines],
          ],
        ),
      ),
    );
  }
}

class _CarteCaisses extends StatelessWidget {
  const _CarteCaisses({required this.r, required this.section});

  final RapportFinancier r;
  final Section section;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final g = r.gestion;
    final recentes = g.caisses.reversed.take(6).toList();
    return _Bloc(
      rapport: r,
      section: section,
      icone: PhosphorIconsLight.cashRegister,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Mesures([
            ('Caisses closes', formatNombre(g.caissesCloses)),
            ('Écart total', formatAmount(g.ecartCaisses)),
          ]),
          const _SousTitre('Dernières caisses'),
          if (recentes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Aucune caisse sur la période.',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13,
                  color: p.textSecondary,
                ),
              ),
            ),
          for (final c in recentes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.agent,
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                        ),
                        Text(
                          c.close
                              ? 'Close le ${formatInstant(c.cloture)}'
                              : 'Ouverte le ${formatInstant(c.ouverture)}',
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 12,
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!c.close)
                    Tag('Ouverte', color: p.accent)
                  else if (c.ecart == 0)
                    Tag('Juste', color: p.success)
                  else
                    Tag(
                      '${c.ecart > 0 ? '+' : ''}${formatAmount(c.ecart)}',
                      color: c.ecart < 0 ? p.error : p.warning,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CarteMenageMaintenance extends StatelessWidget {
  const _CarteMenageMaintenance({
    required this.r,
    required this.section,
    required this.progres,
  });

  final RapportFinancier r;
  final Section section;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    final g = r.gestion;
    return _Bloc(
      rapport: r,
      section: section,
      icone: PhosphorIconsLight.broom,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Mesures([
            ('Chambres faites', '${g.tachesFaites} sur ${g.tachesMenage}'),
            ('Durée moyenne', '${g.dureeMoyenneMenage} min'),
          ]),
          const SizedBox(height: 6),
          BarresParts(
            couleur: AtriumChartColors.types[2],
            progres: progres,
            parts: [
              for (final l in g.menageParAgent.take(5))
                BarrePart(
                  l.agent,
                  l.faites,
                  '${l.faites} chambre${l.faites > 1 ? 's' : ''}',
                ),
            ],
            vide: 'Aucune chambre faite sur la période.',
          ),
          const _SousTitre('Maintenance'),
          _Mesures([
            ('Pannes signalées', formatNombre(g.ticketsSignales)),
            ('Résolues', formatNombre(g.ticketsResolus)),
            ('Délai moyen',
                '${formatDixiemes(g.delaiResolutionDixiemesHeure)} h'),
            ('Coût', formatAmount(g.coutMaintenance)),
          ]),
          const SizedBox(height: 6),
          BarresParts(
            couleur: AtriumChartColors.types[0],
            progres: progres,
            parts: [
              for (final l in g.maintenanceParCategorie.take(5))
                BarrePart(
                  l.categorie,
                  l.tickets,
                  '${l.tickets} panne${l.tickets > 1 ? 's' : ''}',
                  detail: '${l.resolus} résolue${l.resolus > 1 ? 's' : ''}',
                ),
            ],
            vide: 'Aucune panne signalée sur la période.',
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.texte);

  final String texte;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 60),
    child: Center(
      child: Text(
        texte,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 14,
          color: AtriumPalette.current.textSecondary,
        ),
      ),
    ),
  );
}
