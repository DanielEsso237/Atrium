/// Liste des reservations (cahier des charges, F1.1).
///
/// L'ecran de travail de la reception : qui arrive, qui est la, qui est
/// parti. Les filtres suivent la journee d'un receptionniste plutot que les
/// statuts bruts du modele — « attendues » regroupe les reservations en
/// attente et confirmees, parce que la distinction ne change rien a ce qu'il
/// a a faire.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/tokens.dart';

import '../../core/theme.dart';

import '../../core/formats.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';
import 'assign_room_dialog.dart';
import 'stay_actions.dart';

/// Les filtres, tels qu'un receptionniste les pense.
enum ReservationFilter {
  all('Toutes', null),
  expected('Attendues', {
    ReservationStatus.PENDING,
    ReservationStatus.CONFIRMED,
  }),
  inHouse('En cours', {ReservationStatus.CHECKED_IN}),
  done('Terminees', {
    ReservationStatus.CHECKED_OUT,
    ReservationStatus.CANCELLED,
    ReservationStatus.NO_SHOW,
  });

  const ReservationFilter(this.label, this.statuses);

  final String label;
  final Set<ReservationStatus>? statuses;
}

class ReservationFilterNotifier extends Notifier<ReservationFilter> {
  @override
  ReservationFilter build() => ReservationFilter.expected;

  void select(ReservationFilter f) => state = f;
}

final reservationFilterProvider =
    NotifierProvider<ReservationFilterNotifier, ReservationFilter>(
      ReservationFilterNotifier.new,
    );

/// Texte saisi dans la barre de recherche.
class ReservationSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final reservationSearchProvider = NotifierProvider<ReservationSearch, String>(
  ReservationSearch.new,
);

final reservationsProvider = StreamProvider<List<ReservationSummary>>((ref) {
  final filter = ref.watch(reservationFilterProvider);
  final search = ref.watch(reservationSearchProvider).trim().toLowerCase();

  return ref
      .watch(reservationRepositoryProvider)
      .watchReservations(statuses: filter.statuses)
      .map((list) {
        if (search.isEmpty) return list;
        // La recherche porte sur ce qu'un receptionniste a sous les yeux ou
        // au telephone : un nom, une reference, un numero de chambre. Filtrer
        // ici plutot qu'en SQL garde la requete simple, et une reception ne
        // manipule jamais assez de lignes pour que ca se sente.
        return list.where((r) {
          final champs = [
            r.guestName,
            r.reference,
            r.roomNumber ?? '',
            r.roomTypeLabel,
          ].join(' ').toLowerCase();
          return champs.contains(search);
        }).toList();
      });
});

class ReservationsScreen extends ConsumerWidget {
  const ReservationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reservations = ref.watch(reservationsProvider);
    final filter = ref.watch(reservationFilterProvider);
    final schema = Theme.of(context).colorScheme;

    return ModuleScaffold(
      title: 'Réservations',
      action: FilledButton.icon(
        onPressed: () => context.go('/reservations/nouvelle'),
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle réservation'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              onChanged: (v) =>
                  ref.read(reservationSearchProvider.notifier).update(v),
              decoration: const InputDecoration(
                hintText: 'Rechercher un nom, une reference, une chambre…',
                prefixIcon: Icon(Icons.search),
              ),
              style: const TextStyle(fontSize: 18),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                for (final f in ReservationFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: ChoiceChip(
                      label: Text(f.label),
                      selected: filter == f,
                      onSelected: (_) => ref
                          .read(reservationFilterProvider.notifier)
                          .select(f),
                      labelStyle: const TextStyle(fontSize: 16),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: reservations.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Lecture impossible : $e')),
              data: (list) => list.isEmpty
                  ? Center(
                      child: Text(
                        ref.watch(reservationSearchProvider).trim().isEmpty
                            ? 'Aucune reservation dans ce filtre.'
                            : 'Aucune reservation ne correspond a cette '
                                  'recherche.',
                        style: TextStyle(fontSize: 18, color: schema.outline),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, i) =>
                          _ReservationCard(reservation: list[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Libelle et couleur d'un statut de sejour, pris dans les couleurs d'etat
/// de la charte : le plan des chambres et la liste disent la meme chose.
({String label, Color color}) statusAppearance(
  ReservationStatus status,
  ColorScheme schema,
) => switch (status) {
  ReservationStatus.PENDING => (
    label: 'En attente',
    color: CouleursEtat.reservee,
  ),
  ReservationStatus.CONFIRMED => (
    label: 'Confirmée',
    color: CouleursEtat.nettoyage,
  ),
  ReservationStatus.CHECKED_IN => (
    label: 'En cours',
    color: CouleursEtat.disponible,
  ),
  ReservationStatus.CHECKED_OUT => (
    label: 'Terminée',
    color: CouleursEtat.maintenance,
  ),
  ReservationStatus.CANCELLED => (
    label: 'Annulée',
    color: CouleursEtat.occupee,
  ),
  ReservationStatus.NO_SHOW => (
    label: 'Non présente',
    color: CouleursEtat.occupee,
  ),
};

class _ReservationCard extends ConsumerWidget {
  const _ReservationCard({required this.reservation});

  final ReservationSummary reservation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schema = Theme.of(context).colorScheme;
    final look = statusAppearance(reservation.status, schema);

    final arrival = parseIsoDate(reservation.arrival);
    final departure = parseIsoDate(reservation.departure);
    final nights = (arrival != null && departure != null)
        ? departure.difference(arrival).inDays
        : 0;

    final texte = Theme.of(context).textTheme;
    final dates =
        '${arrival == null ? reservation.arrival : formatShortDate(arrival)}'
        '  →  '
        '${departure == null ? reservation.departure : formatShortDate(departure)}'
        // Espaces insecables : « 3 nuits » ne se coupe jamais en fin de ligne.
        '${nights > 0 ? '  ·  $nights\u00a0nuit${nights > 1 ? 's' : ''}' : ''}';

    final identite = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(reservation.guestName, style: texte.titleLarge),
            _Statut(label: look.label, couleur: look.color),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          dates,
          style: texte.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: tabularFigures,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${reservation.reference}  ·  ${reservation.roomTypeLabel}  ·  '
          '${formatAmount(reservation.nightlyRate)} / nuit',
          style: texte.bodySmall,
        ),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder: (context, contraintes) => contraintes.maxWidth < 520
              // Telephone : l'identite en haut, la chambre et l'etape
              // suivante en bas, sur toute la largeur.
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    identite,
                    const SizedBox(height: 14),
                    _RoomAndAction(reservation: reservation, etroit: true),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: identite),
                    const SizedBox(width: 16),
                    _RoomAndAction(reservation: reservation, etroit: false),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Le statut en toutes lettres, sur sa couleur d'etat.
class _Statut extends StatelessWidget {
  const _Statut({required this.label, required this.couleur});

  final String label;
  final Color couleur;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: couleur.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _RoomAndAction extends ConsumerWidget {
  const _RoomAndAction({required this.reservation, required this.etroit});

  final ReservationSummary reservation;
  final bool etroit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schema = Theme.of(context).colorScheme;
    final texte = Theme.of(context).textTheme;

    Widget? bouton;
    if (!reservation.hasRoom) {
      // Une ligne sans chambre est le seul cas qui demande une action
      // immediate de la reception : tant qu'elle n'est pas attribuee, le
      // client ne peut pas arriver.
      bouton = FilledButton.icon(
        onPressed: () => showAssignRoomDialog(context, reservation),
        icon: const Icon(Icons.meeting_room_outlined),
        label: const Text('Attribuer'),
      );
    } else if (reservation.canCheckIn) {
      // Un seul bouton a la fois : l'etape suivante du sejour, jamais les
      // deux. Un sejour termine n'en propose aucun.
      bouton = FilledButton.icon(
        onPressed: () => confirmCheckIn(
          context,
          ref,
          lineId: reservation.lineId,
          guestName: reservation.guestName,
          roomNumber: reservation.roomNumber!,
        ),
        icon: const Icon(Icons.login_rounded),
        label: const Text('Check-in'),
      );
    } else if (reservation.canCheckOut) {
      bouton = OutlinedButton.icon(
        onPressed: () => confirmCheckOut(
          context,
          ref,
          lineId: reservation.lineId,
          guestName: reservation.guestName,
          roomNumber: reservation.roomNumber!,
        ),
        icon: const Icon(Icons.logout_rounded),
        label: const Text('Check-out'),
      );
    }

    final chambre = reservation.hasRoom
        ? Column(
            crossAxisAlignment: etroit
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Chambre', style: texte.labelSmall),
              Text(
                reservation.roomNumber!,
                style: texte.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFeatures: tabularFigures,
                ),
              ),
            ],
          )
        : Text(
            'Sans chambre',
            style: texte.titleSmall?.copyWith(color: schema.error),
          );

    return Row(
      mainAxisSize: etroit ? MainAxisSize.max : MainAxisSize.min,
      children: [
        chambre,
        if (bouton != null) ...[
          const SizedBox(width: 16),
          if (etroit) Expanded(child: bouton) else bouton,
        ],
      ],
    );
  }
}
