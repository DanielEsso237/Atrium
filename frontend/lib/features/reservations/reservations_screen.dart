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

final reservationsProvider = StreamProvider<List<ReservationSummary>>((ref) {
  final filter = ref.watch(reservationFilterProvider);
  return ref
      .watch(reservationRepositoryProvider)
      .watchReservations(statuses: filter.statuses);
});

class ReservationsScreen extends ConsumerWidget {
  const ReservationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reservations = ref.watch(reservationsProvider);
    final filter = ref.watch(reservationFilterProvider);
    final schema = Theme.of(context).colorScheme;

    return ModuleScaffold(
      title: 'Reservations',
      action: FilledButton.icon(
        onPressed: () => context.go('/reservations/nouvelle'),
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle reservation'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
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
                        'Aucune reservation dans ce filtre.',
                        style: TextStyle(fontSize: 18, color: schema.outline),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(24),
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

/// Libelle et couleur d'un statut de sejour.
({String label, Color color}) statusAppearance(
  ReservationStatus status,
  ColorScheme schema,
) => switch (status) {
  ReservationStatus.PENDING => (
    label: 'En attente',
    color: const Color(0xFFF9A825),
  ),
  ReservationStatus.CONFIRMED => (
    label: 'Confirmee',
    color: const Color(0xFF1565C0),
  ),
  ReservationStatus.CHECKED_IN => (
    label: 'En cours',
    color: const Color(0xFF2E7D32),
  ),
  ReservationStatus.CHECKED_OUT => (label: 'Terminee', color: schema.outline),
  ReservationStatus.CANCELLED => (
    label: 'Annulee',
    color: const Color(0xFFC62828),
  ),
  ReservationStatus.NO_SHOW => (
    label: 'Non presente',
    color: const Color(0xFFC62828),
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 6,
              height: 68,
              decoration: BoxDecoration(
                color: look.color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        reservation.guestName,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Chip(
                        label: Text(look.label),
                        backgroundColor: look.color.withValues(alpha: 0.12),
                        side: BorderSide(
                          color: look.color.withValues(alpha: 0.4),
                        ),
                        labelStyle: TextStyle(color: look.color, fontSize: 14),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${reservation.reference} · '
                    '${arrival == null ? reservation.arrival : formatShortDate(arrival)}'
                    ' → '
                    '${departure == null ? reservation.departure : formatShortDate(departure)}'
                    '${nights > 0 ? ' · $nights nuit${nights > 1 ? 's' : ''}' : ''}',
                    style: TextStyle(fontSize: 16, color: schema.outline),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${reservation.roomTypeLabel} · '
                    '${formatAmount(reservation.nightlyRate)} / nuit',
                    style: TextStyle(fontSize: 15, color: schema.outline),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            _RoomAndAction(reservation: reservation),
          ],
        ),
      ),
    );
  }
}

class _RoomAndAction extends ConsumerWidget {
  const _RoomAndAction({required this.reservation});

  final ReservationSummary reservation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schema = Theme.of(context).colorScheme;

    if (!reservation.hasRoom) {
      // Une ligne sans chambre est le seul cas qui demande une action
      // immediate de la reception : tant qu'elle n'est pas attribuee, le
      // client ne peut pas arriver.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'Chambre a attribuer',
            style: TextStyle(fontSize: 15, color: schema.error),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => showAssignRoomDialog(context, reservation),
            icon: const Icon(Icons.meeting_room_outlined),
            label: const Text('Attribuer'),
          ),
        ],
      );
    }

    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'Chambre',
              style: TextStyle(fontSize: 14, color: schema.outline),
            ),
            Text(
              reservation.roomNumber!,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        // Un seul bouton a la fois : l'etape suivante du sejour, jamais les
        // deux. Un sejour termine n'en propose aucun.
        if (reservation.canCheckIn) ...[
          const SizedBox(width: 20),
          FilledButton.icon(
            onPressed: () => confirmCheckIn(
              context,
              ref,
              lineId: reservation.lineId,
              guestName: reservation.guestName,
              roomNumber: reservation.roomNumber!,
            ),
            icon: const Icon(Icons.login),
            label: const Text('Check-in'),
          ),
        ] else if (reservation.canCheckOut) ...[
          const SizedBox(width: 20),
          OutlinedButton.icon(
            onPressed: () => confirmCheckOut(
              context,
              ref,
              lineId: reservation.lineId,
              guestName: reservation.guestName,
              roomNumber: reservation.roomNumber!,
            ),
            icon: const Icon(Icons.logout),
            label: const Text('Check-out'),
          ),
        ],
      ],
    );
  }
}
