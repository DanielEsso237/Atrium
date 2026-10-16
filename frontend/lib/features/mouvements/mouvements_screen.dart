/// Le tableau de bord des mouvements (demande du 16 octobre).
///
/// « Réservations » devient « Mouvements » : tout ce qui entre et sort de
/// l'hotel. Un clic sur l'entree ouvre cet ecran -- la journee en chiffres,
/// les derniers mouvements --, et la fleche du menu deplie ses vues :
/// Nouvelle arrivée, Réservations, Arrivées, Départs, Historique.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/mouvements_queries.dart';
import '../auth/session.dart';
import '../dashboard/dashboard_screen.dart' show dashboardProvider;
import '../reservations/reservations_screen.dart'
    show ReservationFilter, reservationFilterProvider;
import 'annuler_mouvement.dart';
import 'mouvements_widgets.dart';

final _resumeProvider = StreamProvider<ResumeMouvements>((ref) {
  final jour = businessDayFor(DateTime.now());
  return ref
      .watch(databaseProvider)
      .watchResumeMouvements(
        formatIsoDate(jour),
        DateTime(jour.year, jour.month, jour.day, heureBasculeParDefaut),
      );
});

final _derniersProvider = StreamProvider<List<Mouvement>>(
  (ref) => ref.watch(databaseProvider).watchMouvements(limite: 8),
);

class MouvementsScreen extends ConsumerWidget {
  const MouvementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acces = ref.watch(sessionProvider).acces;
    final jour = ref.watch(dashboardProvider).value;
    final resume = ref.watch(_resumeProvider).value;
    final derniers = ref.watch(_derniersProvider).value ?? const [];

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final p = AtriumPalette.current;

    void voir(ReservationFilter f) {
      ref.read(reservationFilterProvider.notifier).select(f);
      context.go('/reservations');
    }

    final arrivees = jour?.arriveesDuJour ?? 0;
    final arriveesFaites = arrivees - (jour?.arriveesRestantes ?? 0);
    final departs = jour?.departsDuJour ?? 0;
    final departsFaits = departs - (jour?.departsRestants ?? 0);
    final peutCreer =
        acces.peut('reservation.create') && acces.peut('folio.write');

    return ModuleScaffold(
      title: 'Mouvements',
      subtitle:
          '${jour?.arriveesRestantes ?? 0} arrivée'
          '${(jour?.arriveesRestantes ?? 0) > 1 ? 's' : ''} et '
          '${jour?.departsRestants ?? 0} départ'
          '${(jour?.departsRestants ?? 0) > 1 ? 's' : ''} '
          "encore à faire aujourd'hui",
      action: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          if (acces.peut('reservation.create'))
            PillButton(
              label: 'Faire une réservation',
              icon: PhosphorIconsLight.calendarPlus,
              tone: PillTone.quiet,
              onPressed: () => context.go('/reservations/nouvelle'),
            ),
          if (peutCreer)
            PillButton(
              label: 'Nouvelle arrivée',
              icon: PhosphorIconsLight.doorOpen,
              tone: PillTone.accent,
              onPressed: () => context.go('/reservations/arrivee-directe'),
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
        children: [
          FadeUp(
            child: GrilleTuiles(
              tuiles: [
                TuileChiffre(
                  libelle: "Arrivées aujourd'hui",
                  valeur: '$arriveesFaites / $arrivees',
                  icone: PhosphorIconsLight.signIn,
                  aide: (jour?.arriveesRestantes ?? 0) == 0
                      ? 'Toutes les arrivées sont faites'
                      : '${jour!.arriveesRestantes} encore attendue'
                            '${jour.arriveesRestantes > 1 ? 's' : ''}',
                  onTap: () => voir(ReservationFilter.arrivalsToday),
                ),
                TuileChiffre(
                  libelle: "Départs aujourd'hui",
                  valeur: '$departsFaits / $departs',
                  icone: PhosphorIconsLight.signOut,
                  aide: (jour?.departsRestants ?? 0) == 0
                      ? 'Tous les départs sont faits'
                      : '${jour!.departsRestants} encore à faire',
                  alerte: (jour?.departsRestants ?? 0) > 0 &&
                      DateTime.now().hour >= 12,
                  onTap: () => voir(ReservationFilter.departuresToday),
                ),
                TuileChiffre(
                  libelle: 'En séjour',
                  valeur: '${resume?.enSejour ?? 0}',
                  icone: PhosphorIconsLight.bed,
                  aide: jour?.tauxOccupation == null
                      ? null
                      : "Taux d'occupation ${jour!.tauxOccupation} %",
                  onTap: () => voir(ReservationFilter.inHouse),
                ),
                TuileChiffre(
                  libelle: 'À venir sur 7 jours',
                  valeur: '${resume?.aVenir ?? 0}',
                  icone: PhosphorIconsLight.calendarDots,
                  aide: 'Arrivées prévues, aujourd’hui exclu',
                  onTap: () => voir(ReservationFilter.expected),
                ),
                TuileChiffre(
                  libelle: "Réservations prises aujourd'hui",
                  valeur: '${resume?.prisesAujourdhui ?? 0}',
                  icone: PhosphorIconsLight.calendarPlus,
                  onTap: () => voir(ReservationFilter.all),
                ),
                TuileChiffre(
                  libelle: "Arrivées directes aujourd'hui",
                  valeur: '${resume?.directesAujourdhui ?? 0}',
                  icone: PhosphorIconsLight.doorOpen,
                  aide: 'Sans réservation',
                ),
                TuileChiffre(
                  libelle: 'Sans chambre attribuée',
                  valeur: '${resume?.sansChambre ?? 0}',
                  icone: PhosphorIconsLight.warningCircle,
                  alerte: (resume?.sansChambre ?? 0) > 0,
                  aide: "Arrivées d'aujourd'hui et de demain",
                  onTap: () => voir(ReservationFilter.expected),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Eyebrow(
            'Derniers mouvements',
            trailing: TextButton.icon(
              onPressed: () => context.go('/mouvements/historique'),
              icon: const Icon(
                PhosphorIconsLight.clockCounterClockwise,
                size: 18,
              ),
              label: const Text("Tout l'historique"),
            ),
          ),
          const SizedBox(height: 10),
          Bezel(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            child: derniers.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      "Aucun mouvement pour l'instant.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.textSecondary, fontSize: 15),
                    ),
                  )
                : Column(
                    children: [
                      for (final m in derniers)
                        LigneMouvement(
                          mouvement: m,
                          avecDate: true,
                          onClient: m.guestId == null
                              ? null
                              : () => context.go(
                                  '/mouvements/historique?client=${m.guestId}',
                                ),
                          onAnnuler: peutProposerAnnulation(acces, m)
                              ? () => annulerMouvement(context, ref, m)
                              : null,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
