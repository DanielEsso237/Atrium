/// Attribution d'une chambre a un sejour (cahier des charges, F1.3).
///
/// Ne propose que les chambres reellement libres sur la periode : meme
/// categorie, ni hors service, ni deja prises par un sejour qui chevauche.
/// Le calcul vit dans le depot, pas ici — un ecran ne doit pas pouvoir
/// proposer une chambre que la base refuserait.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';
import '../auth/session.dart';

void showAssignRoomDialog(
  BuildContext context,
  ReservationSummary reservation,
) {
  showDialog<void>(
    context: context,
    builder: (_) => _AssignRoomDialog(reservation: reservation),
  );
}

class _AssignRoomDialog extends ConsumerStatefulWidget {
  const _AssignRoomDialog({required this.reservation});

  final ReservationSummary reservation;

  @override
  ConsumerState<_AssignRoomDialog> createState() => _AssignRoomDialogState();
}

class _AssignRoomDialogState extends ConsumerState<_AssignRoomDialog> {
  late Future<List<AvailableRoom>> _rooms;
  String? _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final r = widget.reservation;
    _rooms = ref
        .read(reservationRepositoryProvider)
        .availableRooms(
          roomTypeId: r.roomTypeId,
          arrival: parseIsoDate(r.arrival) ?? DateTime.now(),
          departure: parseIsoDate(r.departure) ?? DateTime.now(),
        );
  }

  Future<void> _assign() async {
    if (_selected == null) return;
    setState(() => _busy = true);

    await ref
        .read(reservationRepositoryProvider)
        .assignRoom(
          lineId: widget.reservation.lineId,
          roomId: _selected!,
          by: ref.read(sessionProvider).agent?.id,
        );

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Chambre attribuée.')));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reservation;
    final p = AtriumPalette.current;
    final a = parseIsoDate(r.arrival);
    final d = parseIsoDate(r.departure);

    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.door, size: 32),
      title: Text('Une chambre pour ${r.guestName}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${r.roomTypeLabel}, du '
              '${a == null ? r.arrival : formatDayMonth(a)} au '
              '${d == null ? r.departure : formatDayMonth(d)}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
            const SizedBox(height: 18),
            FutureBuilder<List<AvailableRoom>>(
              future: _rooms,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final rooms = snap.data!;
                if (rooms.isEmpty) {
                  return Row(
                    children: [
                      Icon(PhosphorIconsLight.warningCircle, color: p.warning),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Aucune chambre libre de cette catégorie sur la période.',
                        ),
                      ),
                    ],
                  );
                }
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final room in rooms)
                      RoomChoiceTile(
                        numero: room.number,
                        choisie: _selected == room.id,
                        onTap: () => setState(() => _selected = room.id),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: (_selected == null || _busy) ? null : _assign,
          child: const Text('Attribuer'),
        ),
      ],
    );
  }
}
