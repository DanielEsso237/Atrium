/// Le rapport d'un module (F3.3, demande du 19 octobre) : l'onglet Rapport
/// de la reception, des ventes, des stocks et de l'entretien.
///
/// En haut, les filtres du module -- la periode toujours, puis le point de
/// vente, l'agent ou le type de chambre selon le module. Dessous, le
/// document tel qu'il sortira : l'en-tete de l'hotel avec son logo, les
/// chiffres, les registres, les cases de signature. Deux boutons
/// l'exportent en PDF ou en Excel, a partager ou imprimer.
///
/// Un agent rattache a des points de vente (le barman) n'y voit que les
/// siens : son rapport des ventes s'ouvre sur son comptoir, jamais sur
/// tout l'hotel.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database.dart' show OutletRow;
import '../../data/local/queries/report_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../hotel/en_tete_hotel.dart' show lignesCoordonnees;
import 'apercu_document.dart';
import 'export/export_model.dart';
import 'export/exporter.dart';
import 'export/partage.dart';
import 'filtre_rapport.dart';
import 'rapports_modules.dart';
import 'report_state.dart';

class RapportModuleScreen extends ConsumerStatefulWidget {
  const RapportModuleScreen({super.key, required this.module});

  final ModuleRapport module;

  @override
  ConsumerState<RapportModuleScreen> createState() =>
      _RapportModuleScreenState();
}

class _RapportModuleScreenState extends ConsumerState<RapportModuleScreen> {
  var _periode = Periode.ceMois;
  late FiltresRapport _filtres = () {
    final (du, au) = _periode.bornes(businessDayFor(DateTime.now()));
    return FiltresRapport(du: du, au: au);
  }();

  void _choisirPeriode(Periode p) {
    final (du, au) = p.bornes(businessDayFor(DateTime.now()));
    setState(() {
      _periode = p;
      _filtres = _filtres.copier(du: du, au: au);
    });
  }

  Future<void> _choisirDates() async {
    final aujourdhui = businessDayFor(DateTime.now());
    final choix = await showDateRangePicker(
      context: context,
      firstDate: DateTime(aujourdhui.year - 3),
      lastDate: aujourdhui,
      initialDateRange: DateTimeRange(start: _filtres.du, end: _filtres.au),
      helpText: 'Période du rapport',
      saveText: 'Afficher',
      cancelText: 'Annuler',
    );
    if (choix == null || !mounted) return;
    setState(() {
      _periode = Periode.personnalisee;
      _filtres = _filtres.copier(du: choix.start, au: choix.end);
    });
  }

  @override
  Widget build(BuildContext context) {
    final module = widget.module;
    final session = ref.watch(sessionProvider);
    final acces = session.acces;
    final agentId = session.agent?.id;

    // Les points de vente que l'agent peut regarder : les siens s'il y est
    // rattache, tous sinon.
    final tousLesPoints =
        ref.watch(pointsDeVenteRapportProvider).value ?? const <OutletRow>[];
    final perimetre = agentId == null
        ? null
        : ref.watch(perimetrePdvProvider(agentId)).value;
    final rattache = perimetre?.rattache ?? false;
    final points = rattache ? perimetre!.pointsDeVente : tousLesPoints;
    // Rattache : jamais « tous », toujours l'un des siens.
    final filtres =
        module.filtrePointDeVente &&
            rattache &&
            points.isNotEmpty &&
            !points.any((o) => o.id == _filtres.pointDeVenteId)
        ? _filtres.copier(pointDeVenteId: () => points.first.id)
        : _filtres;

    final rapport = ref.watch(rapportProvider(filtres));
    final registres = ref.watch(registresProvider((module, filtres)));
    final fiche = ref.watch(hotelProvider).value;
    final nomHotel = ref.watch(nomHotelProvider).value ?? 'Hôtel';
    final agents = ref.watch(agentsRapportProvider).value ?? const [];
    final types = ref.watch(typesChambreRapportProvider).value ?? const [];

    final pret = rapport.hasValue && registres.hasValue;
    final sections = pret
        ? sectionsDuModule(module, rapport.value!, registres.value!, acces)
        : const <Section>[];
    final doc = DocumentRapport(
      titre: module.titre,
      hotel: fiche?.name ?? nomHotel,
      logo: fiche?.logoData,
      coordonnees: lignesCoordonnees(fiche),
      periode: libellePeriode(filtres),
      filtres: libellesFiltres(
        filtres,
        pointsDeVente: tousLesPoints,
        agents: agents,
        types: types,
      ),
      etabliLe: DateTime.now(),
      etabliPar: switch (session.agent) {
        final a? => '${a.firstName} ${a.lastName}'.trim(),
        null => null,
      },
      visas: ModuleRapport.visas,
      sections: sections,
    );

    String? nom<T>(List<T> l, String? id, String Function(T) cle,
        String Function(T) lire) {
      for (final e in l) {
        if (cle(e) == id) return lire(e);
      }
      return null;
    }

    void exporter(FormatExport format) => exporterRapport(
      context: context,
      ref: ref,
      filtres: filtres,
      titre: module.titre,
      sections: sections,
      format: format,
      visas: ModuleRapport.visas,
    );

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    return ModuleScaffold(
      title: module.titre,
      subtitle: libellePeriode(filtres),
      action: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          PillButton(
            label: 'Excel',
            icon: PhosphorIconsLight.fileXls,
            tone: PillTone.quiet,
            onPressed: pret ? () => exporter(FormatExport.excel) : null,
          ),
          PillButton(
            label: 'Exporter en PDF',
            icon: PhosphorIconsLight.filePdf,
            tone: PillTone.accent,
            onPressed: pret ? () => exporter(FormatExport.pdf) : null,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FiltreRapport<Periode>(
                  icone: PhosphorIconsLight.calendarBlank,
                  libelle: _periode == Periode.personnalisee
                      ? libellePeriode(filtres)
                      : _periode.libelle,
                  actif: true,
                  choix: [
                    for (final p in Periode.values)
                      (
                        p,
                        p == Periode.personnalisee
                            ? 'Choisir les dates…'
                            : p.libelle,
                      ),
                  ],
                  courant: _periode,
                  surChoix: (p) => p == Periode.personnalisee
                      ? _choisirDates()
                      : _choisirPeriode(p!),
                  sansTous: true,
                ),
                if (module.filtrePointDeVente &&
                    (!rattache || points.length > 1))
                  FiltreRapport<String>(
                    icone: PhosphorIconsLight.storefront,
                    libelle:
                        nom(points, filtres.pointDeVenteId, (o) => o.id,
                            (o) => o.label) ??
                        'Point de vente',
                    actif: filtres.pointDeVenteId != null,
                    tous: 'Tous les points de vente',
                    sansTous: rattache,
                    choix: [for (final o in points) (o.id, o.label)],
                    courant: filtres.pointDeVenteId,
                    surChoix: (id) => setState(
                      () => _filtres = _filtres.copier(pointDeVenteId: () => id),
                    ),
                  ),
                FiltreRapport<String>(
                  icone: PhosphorIconsLight.user,
                  libelle:
                      nom(agents, filtres.agentId, (u) => u.id,
                          (u) => '${u.firstName} ${u.lastName}') ??
                      'Agent',
                  actif: filtres.agentId != null,
                  tous: 'Tous les agents',
                  choix: [
                    for (final u in agents)
                      (u.id, '${u.firstName} ${u.lastName}'),
                  ],
                  courant: filtres.agentId,
                  surChoix: (id) => setState(
                    () => _filtres = _filtres.copier(agentId: () => id),
                  ),
                ),
                if (module.filtreTypeChambre)
                  FiltreRapport<String>(
                    icone: PhosphorIconsLight.bed,
                    libelle:
                        nom(types, filtres.typeChambreId, (t) => t.id,
                            (t) => t.label) ??
                        'Type de chambre',
                    actif: filtres.typeChambreId != null,
                    tous: 'Tous les types',
                    choix: [for (final t in types) (t.id, t.label)],
                    courant: filtres.typeChambreId,
                    surChoix: (id) => setState(
                      () => _filtres = _filtres.copier(typeChambreId: () => id),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: !pret
                ? (rapport.hasError || registres.hasError)
                      ? EmptyState(
                          icon: PhosphorIconsLight.warningCircle,
                          title: 'Lecture impossible',
                          message: '${rapport.error ?? registres.error}',
                        )
                      : const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(marge, 4, marge, 40),
                    child: Center(
                      child: ConstrainedBox(
                        // La largeur d'une feuille A4 a l'ecran.
                        constraints: const BoxConstraints(maxWidth: 900),
                        child: ApercuDocument(doc: doc),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
