/// L'entretien de l'hotel : le menage et la maintenance (demande du
/// 16 octobre).
///
/// Un clic sur « Entretien » ouvre ce mini tableau de bord : deux tuiles,
/// une par metier, chacune avec ses chiffres et le bouton qui ouvre son
/// ecran. La fleche du menu deplie les deux ecrans, Ménage et Maintenance.
/// Chaque tuile ne s'affiche qu'a qui a le droit de lire son metier.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../core/widgets/tuile_metier.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/mouvements_queries.dart';
import '../auth/session.dart';

final _entretienProvider = StreamProvider<ResumeEntretien>(
  (ref) => ref.watch(databaseProvider).watchResumeEntretien(businessDateNow()),
);

class EntretienScreen extends ConsumerWidget {
  const EntretienScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acces = ref.watch(sessionProvider).acces;
    final r = ref.watch(_entretienProvider).value;
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    List<Widget> tuilesPour({required bool etiree}) => <Widget>[
      if (acces.peut('housekeeping.read'))
        TuileMetier(
          titre: 'Ménage',
          icone: PhosphorIconsLight.broom,
          phrase: r == null
              ? '…'
              : r.sales == 0
              ? 'Toutes les chambres sont propres.'
              : '${r.sales} chambre${r.sales > 1 ? 's' : ''} à nettoyer.',
          alerte: (r?.sales ?? 0) > 0,
          progression: r == null || r.chambres == 0
              ? null
              : r.propres / r.chambres,
          legende: r == null
              ? null
              : '${r.propres} propre${r.propres > 1 ? 's' : ''} '
                    'sur ${r.chambres}',
          chiffres: [
            ('À nettoyer', '${r?.sales ?? 0}', (r?.sales ?? 0) > 0),
            ('En cours', '${r?.enCours ?? 0}', false),
            ('Propres', '${r?.propres ?? 0}', false),
            (
              "Tâches du jour",
              '${r?.tachesFaites ?? 0} / ${r?.taches ?? 0}',
              false,
            ),
            (
              'Non assignées',
              '${r?.nonAssignees ?? 0}',
              (r?.nonAssignees ?? 0) > 0,
            ),
          ],
          bouton: 'Ouvrir le ménage',
          onOuvrir: () => context.go('/menage'),
          etiree: etiree,
        ),
      if (acces.peut('maintenance.read'))
        TuileMetier(
          titre: 'Maintenance',
          icone: PhosphorIconsLight.wrench,
          phrase: r == null
              ? '…'
              : r.ticketsOuverts == 0
              ? 'Aucun ticket ouvert.'
              : '${r.ticketsOuverts} ticket${r.ticketsOuverts > 1 ? 's' : ''} '
                    'ouvert${r.ticketsOuverts > 1 ? 's' : ''}'
                    '${r.urgents > 0 ? ', dont ${r.urgents} urgent${r.urgents > 1 ? 's' : ''}' : ''}.',
          alerte: (r?.urgents ?? 0) > 0,
          progression: r == null || r.chambres == 0
              ? null
              : (r.chambres - r.horsService) / r.chambres,
          legende: r == null
              ? null
              : '${r.chambres - r.horsService} chambre'
                    '${r.chambres - r.horsService > 1 ? 's' : ''} en service '
                    'sur ${r.chambres}',
          chiffres: [
            ('Ouverts', '${r?.ticketsOuverts ?? 0}', false),
            ('Urgents', '${r?.urgents ?? 0}', (r?.urgents ?? 0) > 0),
            ('En intervention', '${r?.enIntervention ?? 0}', false),
            (
              'Hors service',
              '${r?.horsService ?? 0}',
              (r?.horsService ?? 0) > 0,
            ),
            ('Résolus sur 7 jours', '${r?.resolus7Jours ?? 0}', false),
          ],
          bouton: 'Ouvrir la maintenance',
          onOuvrir: () => context.go('/maintenance'),
          etiree: etiree,
        ),
    ];

    return ModuleScaffold(
      title: 'Entretien',
      subtitle: 'Le ménage et la maintenance, en un coup d’œil',
      body: LayoutBuilder(
        builder: (context, zone) {
          final cote =
              zone.maxWidth >= 900 && tuilesPour(etiree: false).length > 1;
          final tuiles = tuilesPour(etiree: cote);
          return ListView(
            padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
            children: [
              if (cote)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: FadeUp(child: tuiles[0])),
                      const SizedBox(width: 16),
                      Expanded(child: FadeUp(index: 1, child: tuiles[1])),
                    ],
                  ),
                )
              else
                for (var i = 0; i < tuiles.length; i++) ...[
                  if (i > 0) const SizedBox(height: 16),
                  FadeUp(index: i, child: tuiles[i]),
                ],
            ],
          );
        },
      ),
    );
  }
}
