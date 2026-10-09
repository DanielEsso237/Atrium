/// Le geste d'export : composer le document, le fabriquer, le remettre.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formats.dart';
import '../../../data/local/queries/report_queries.dart';
import '../report_state.dart';
import 'excel_export.dart';
import 'export_model.dart';
import 'partage.dart';
import 'pdf_export.dart';

/// Exporte `sections` au `format` demande et dit a l'agent ce qui s'est
/// passe. `titre` nomme le document et le fichier.
Future<void> exporterRapport({
  required BuildContext context,
  required WidgetRef ref,
  required FiltresRapport filtres,
  required String titre,
  required List<Section> sections,
  required FormatExport format,
}) async {
  final messager = ScaffoldMessenger.of(context);
  final boite = context.findRenderObject() as RenderBox?;
  final origine = boite == null
      ? null
      : boite.localToGlobal(Offset.zero) & boite.size;

  try {
    final doc = DocumentRapport(
      titre: titre,
      hotel: await ref.read(nomHotelProvider.future),
      periode: libellePeriode(filtres),
      filtres: libellesFiltres(
        filtres,
        pointsDeVente: ref.read(pointsDeVenteRapportProvider).value ?? const [],
        agents: ref.read(agentsRapportProvider).value ?? const [],
        types: ref.read(typesChambreRapportProvider).value ?? const [],
      ),
      etabliLe: DateTime.now(),
      sections: sections,
    );
    final octets = switch (format) {
      FormatExport.pdf => await construirePdf(doc),
      FormatExport.excel => construireExcel(doc),
    };
    final remis = await partagerFichier(
      octets: octets,
      nom: doc.nomFichier(formatIsoDate(filtres.du), formatIsoDate(filtres.au)),
      format: format,
      sujet: '$titre : ${doc.periode}',
      origine: origine,
    );
    if (remis) {
      messager.showSnackBar(
        SnackBar(content: Text('$titre exporté en ${format.libelle}.')),
      );
    }
  } catch (e) {
    messager.showSnackBar(
      SnackBar(
        content: Text(
          "L'export ${format.libelle} n'a pas abouti : $e. "
          'Réessayez ; si cela persiste, signalez-le avec ce message.',
        ),
      ),
    );
  }
}
