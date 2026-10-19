/// Le geste d'export : composer le document, le fabriquer, le remettre.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formats.dart';
import '../../../data/local/queries/report_queries.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../auth/session.dart';
import '../../hotel/en_tete_hotel.dart';
import '../report_state.dart';
import 'excel_export.dart';
import 'export_model.dart';
import 'partage.dart';
import 'pdf_export.dart';

import '../../../core/ui/confirmation.dart';

/// Exporte `sections` au `format` demande et dit a l'agent ce qui s'est
/// passe. `titre` nomme le document et le fichier ; `visas`, les cases de
/// signature en fin de document (les rapports des modules, F3.3).
Future<void> exporterRapport({
  required BuildContext context,
  required WidgetRef ref,
  required FiltresRapport filtres,
  required String titre,
  required List<Section> sections,
  required FormatExport format,
  List<String> visas = const [],
}) async {
  final boite = context.findRenderObject() as RenderBox?;
  final origine = boite == null
      ? null
      : boite.localToGlobal(Offset.zero) & boite.size;

  try {
    // Le meme en-tete que la facture : le logo et les coordonnees de
    // l'hotel, regles dans l'administration.
    final fiche = await ref.read(hotelProvider.future);
    final doc = DocumentRapport(
      titre: titre,
      hotel: fiche?.name ?? await ref.read(nomHotelProvider.future),
      logo: fiche?.logoData,
      coordonnees: lignesCoordonnees(fiche),
      periode: libellePeriode(filtres),
      filtres: libellesFiltres(
        filtres,
        pointsDeVente: ref.read(pointsDeVenteRapportProvider).value ?? const [],
        agents: ref.read(agentsRapportProvider).value ?? const [],
        types: ref.read(typesChambreRapportProvider).value ?? const [],
      ),
      etabliLe: DateTime.now(),
      etabliPar: switch (ref.read(sessionProvider).agent) {
        final a? => '${a.firstName} ${a.lastName}'.trim(),
        null => null,
      },
      visas: visas,
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
    if (remis && context.mounted) {
      montrerSucces(context, '$titre exporté en ${format.libelle}.');
    }
  } catch (e) {
    if (context.mounted) {
      montrerRefus(
        context,
        "L'export ${format.libelle} n'a pas abouti : $e. "
        'Réessayez ; si cela persiste, signalez-le avec ce message.',
      );
    }
  }
}
