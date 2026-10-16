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
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
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
        _TuileMetier(
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
            ('Non assignées', '${r?.nonAssignees ?? 0}', (r?.nonAssignees ?? 0) > 0),
          ],
          bouton: 'Ouvrir le ménage',
          onOuvrir: () => context.go('/menage'),
          etiree: etiree,
        ),
      if (acces.peut('maintenance.read'))
        _TuileMetier(
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
            ('Hors service', '${r?.horsService ?? 0}', (r?.horsService ?? 0) > 0),
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

/// La tuile d'un metier : une phrase qui dit l'essentiel, une jauge, les
/// chiffres, et le bouton qui ouvre l'ecran.
class _TuileMetier extends StatelessWidget {
  const _TuileMetier({
    required this.titre,
    required this.icone,
    required this.phrase,
    required this.chiffres,
    required this.bouton,
    required this.onOuvrir,
    this.alerte = false,
    this.progression,
    this.legende,
    this.etiree = false,
  });

  /// Posee dans une rangee de hauteur fixe (cote a cote).
  final bool etiree;

  final String titre;
  final IconData icone;
  final String phrase;
  final bool alerte;

  /// Entre 0 et 1 ; `null` : pas de jauge.
  final double? progression;
  final String? legende;

  /// Libelle, valeur, a surveiller.
  final List<(String, String, bool)> chiffres;
  final String bouton;
  final VoidCallback onOuvrir;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: p.accentTint,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: p.accentSoft),
                ),
                child: Icon(icone, size: 24, color: p.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titre, style: atriumDisplay(26, color: p.text)),
                    Text(
                      phrase,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: alerte ? p.error : p.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (progression != null) ...[
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progression!.clamp(0, 1),
                minHeight: 10,
                backgroundColor: p.surfaceMuted,
                color: p.success,
              ),
            ),
            if (legende != null) ...[
              const SizedBox(height: 6),
              Text(
                legende!,
                style: TextStyle(
                  fontSize: 13,
                  color: p.textSecondary,
                  fontFeatures: tabularFigures,
                ),
              ),
            ],
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final (libelle, valeur, aSurveiller) in chiffres)
                Container(
                  constraints: const BoxConstraints(minWidth: 118),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: aSurveiller
                        ? p.error.withValues(alpha: 0.08)
                        : p.surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        valeur,
                        style: atriumDisplay(
                          22,
                          color: aSurveiller ? p.error : p.text,
                        ).copyWith(fontFeatures: tabularFigures),
                      ),
                      Text(
                        libelle,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: p.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          // Cote a cote, les deux boutons s'alignent en bas ; empilees, la
          // tuile n'a pas de hauteur imposee et le bouton suit les chiffres.
          if (etiree) const Spacer(),
          const SizedBox(height: 20),
          PillButton(
            label: bouton,
            icon: PhosphorIconsLight.arrowRight,
            tone: PillTone.accent,
            expand: true,
            onPressed: onOuvrir,
          ),
        ],
      ),
    );
  }
}
