/// Sous les tuiles d'un point de vente : la journee en un coup d'oeil
/// (demande du 15 octobre). En haut quelques chiffres, en dessous les
/// dernieres ventes -- ce qui vient d'etre servi, a qui, et ou en est
/// l'argent.
///
/// La recette s'affiche, tiroir ouvert ou non (decision du 15 octobre) :
/// chaque vente dit deja son montant.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../data/local/database.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/historique_pdv_queries.dart';
import '../../data/local/queries/outlet_dashboard_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

final _dernieresVentesProvider =
    StreamProvider.family<List<VentePdv>, (String, DateTime)>(
      (ref, cle) => ref
          .watch(databaseProvider)
          .watchDernieresVentesPdv(pointDeVente: cle.$1, jour: cle.$2),
    );

class HistoriqueDuJour extends ConsumerWidget {
  const HistoriqueDuJour({super.key, required this.outlet});

  final OutletRow outlet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final jour = businessDayFor(DateTime.now());
    final acces = ref.watch(sessionProvider).acces;
    final tableau = ref
        .watch(
          tableauDeBordPdvProvider(
            FiltresPdv(
              pointsDeVente: [outlet.id],
              periode: PeriodePdv.jour,
              reference: jour,
            ),
          ),
        )
        .value;
    final ventes =
        ref.watch(_dernieresVentesProvider((outlet.id, jour))).value ??
        const <VentePdv>[];
    final c = tableau?.chiffres ?? const ChiffresPdv();
    final meilleures = tableau?.meilleuresVentes.take(3).toList() ?? const [];

    final chiffre = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 20,
      fontWeight: FontWeight.w800,
      color: p.text,
      fontFeatures: tabularFigures,
    );
    final legende = TextStyle(fontSize: 12.5, color: p.textSecondary);
    Widget case_(String valeur, String libelle) => SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(valeur, style: chiffre),
          Text(libelle, style: legende),
        ],
      ),
    );

    return Bezel(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(
            'Aujourd’hui à ${outlet.label}',
            trailing: acces.peut('order.read')
                ? TextButton(
                    onPressed: () => context.go('/ventes'),
                    child: const Text('Tout voir'),
                  )
                : null,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              case_('${c.ventes}', 'vente${c.ventes > 1 ? 's' : ''}'),
              case_('${c.articles}', 'article${c.articles > 1 ? 's' : ''}'),
              case_(formatAmount(c.recette), 'recette'),
              case_(formatAmount(c.aPayer), 'à payer (ardoises)'),
            ],
          ),
          if (meilleures.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Meilleures ventes : '
              '${meilleures.map((m) => '${m.libelle} ×${m.quantite}').join(', ')}',
              style: legende.copyWith(fontSize: 13.5),
            ),
          ],
          const Divider(height: 26),
          if (ventes.isEmpty)
            Text('Rien de servi pour l’instant.', style: legende)
          else
            for (final v in ventes) _Vente(vente: v),
        ],
      ),
    );
  }
}

String _hm(DateTime d) {
  final l = d.toLocal();
  return '${l.hour} h ${l.minute.toString().padLeft(2, '0')}';
}

class _Vente extends StatelessWidget {
  const _Vente({required this.vente});

  final VentePdv vente;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final v = vente;
    final (etat, couleur) = switch (v.etat) {
      EtatVentePdv.payee => ('Payée', p.success),
      EtatVentePdv.aPayer => ('À payer', p.warning),
      EtatVentePdv.enChambre => ('Sur la chambre', p.textSecondary),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              v.derniereLe == null ? '' : _hm(v.derniereLe!),
              style: TextStyle(
                fontSize: 13,
                color: p.textSecondary,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.titre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
                Text(
                  v.articles,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatAmount(v.montant),
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: p.text,
              fontFeatures: tabularFigures,
            ),
          ),
          const SizedBox(width: 10),
          Tag(etat, color: couleur),
        ],
      ),
    );
  }
}
