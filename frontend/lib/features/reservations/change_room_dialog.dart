/// Le choix d'une autre chambre pour un client deja arrive.
///
/// Cette fenetre ne fait que choisir : elle renvoie la chambre retenue, et
/// c'est `confirmChangeRoom` qui fait le geste, comme `confirmCheckIn` fait
/// l'arrivee. La liste vient du depot -- un ecran ne doit pas pouvoir
/// proposer une chambre que la base refuserait.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';

/// Renvoie la chambre choisie, ou `null` si l'agent renonce.
Future<AvailableRoom?> pickRoomForChange(
  BuildContext context, {
  required String lineId,
  required String guestName,
  required String currentRoomNumber,
}) {
  return showDialog<AvailableRoom>(
    context: context,
    builder: (_) => _ChangeRoomDialog(
      lineId: lineId,
      guestName: guestName,
      currentRoomNumber: currentRoomNumber,
    ),
  );
}

class _ChangeRoomDialog extends ConsumerStatefulWidget {
  const _ChangeRoomDialog({
    required this.lineId,
    required this.guestName,
    required this.currentRoomNumber,
  });

  final String lineId;
  final String guestName;
  final String currentRoomNumber;

  @override
  ConsumerState<_ChangeRoomDialog> createState() => _ChangeRoomDialogState();
}

class _ChangeRoomDialogState extends ConsumerState<_ChangeRoomDialog> {
  late Future<List<AvailableRoom>> _rooms;
  AvailableRoom? _selected;

  @override
  void initState() {
    super.initState();
    _rooms = ref
        .read(reservationRepositoryProvider)
        .roomsForChange(widget.lineId);
  }

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text('Changer la chambre de ${widget.guestName}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Actuellement en chambre ${widget.currentRoomNumber}. '
              'Chambres libres et propres de la meme categorie :',
              style: TextStyle(fontSize: 16, color: schema.outline),
            ),
            const SizedBox(height: 16),
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
                  return Text(
                    'Aucune chambre libre et propre de cette categorie.',
                    style: TextStyle(fontSize: 17, color: schema.error),
                  );
                }
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final room in rooms)
                      ChoiceChip(
                        label: Text(
                          room.number,
                          style: const TextStyle(fontSize: 18),
                        ),
                        selected: _selected?.id == room.id,
                        onSelected: (_) => setState(() => _selected = room),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _selected == null
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: const Text('Choisir'),
        ),
      ],
    );
  }
}
