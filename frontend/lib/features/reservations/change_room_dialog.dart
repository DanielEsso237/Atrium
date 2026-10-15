/// Le choix d'une autre chambre pour un client deja arrive.
///
/// Cette fenetre ne fait que choisir : elle renvoie la chambre retenue, et
/// c'est `confirmChangeRoom` qui fait le geste, comme `confirmCheckIn` fait
/// l'arrivee. La liste vient du depot -- un ecran ne doit pas pouvoir
/// proposer une chambre que la base refuserait.
///
/// Le surclassement (demande du 14 octobre) : les chambres des categories
/// superieures sont proposees a part. Une chambre choisie la porte sa
/// categorie (`AvailableRoom.categorie`) : c'est a ca que l'appelant sait
/// qu'il faut demander le motif.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/ui/icons.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';

/// Renvoie la chambre choisie, ou `null` si l'agent renonce.
///
/// `surclassementSeulement` : a l'arrivee, la chambre attribuee est deja
/// connue ; on ne cherche qu'une chambre superieure.
Future<AvailableRoom?> pickRoomForChange(
  BuildContext context, {
  required String lineId,
  required String guestName,
  required String currentRoomNumber,
  bool surclassementSeulement = false,
}) {
  return showDialog<AvailableRoom>(
    context: context,
    builder: (_) => _ChangeRoomDialog(
      lineId: lineId,
      guestName: guestName,
      currentRoomNumber: currentRoomNumber,
      surclassementSeulement: surclassementSeulement,
    ),
  );
}

class _ChangeRoomDialog extends ConsumerStatefulWidget {
  const _ChangeRoomDialog({
    required this.lineId,
    required this.guestName,
    required this.currentRoomNumber,
    required this.surclassementSeulement,
  });

  final String lineId;
  final String guestName;
  final String currentRoomNumber;
  final bool surclassementSeulement;

  @override
  ConsumerState<_ChangeRoomDialog> createState() => _ChangeRoomDialogState();
}

class _ChangeRoomDialogState extends ConsumerState<_ChangeRoomDialog> {
  late Future<(List<AvailableRoom>, List<AvailableRoom>)> _rooms;
  AvailableRoom? _selected;

  @override
  void initState() {
    super.initState();
    final depot = ref.read(reservationRepositoryProvider);
    _rooms = () async {
      final memes = widget.surclassementSeulement
          ? const <AvailableRoom>[]
          : await depot.roomsForChange(widget.lineId);
      final superieures = await depot.roomsForChange(
        widget.lineId,
        surclassement: true,
      );
      return (memes, superieures);
    }();
  }

  Widget _puces(List<AvailableRoom> rooms) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final room in rooms)
        ChoiceChip(
          label: Text(
            room.categorie == null
                ? room.number
                : '${room.number} · ${room.categorie}',
            style: const TextStyle(fontSize: 18),
          ),
          tooltip: room.tarif == null
              ? null
              : '${formatAmount(room.tarif!)} la nuit',
          selected: _selected?.id == room.id,
          onSelected: (_) => setState(() => _selected = room),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final legende = TextStyle(fontSize: 16, color: schema.outline);

    return AlertDialog(
      title: Text(
        widget.surclassementSeulement
            ? 'Une chambre supérieure pour ${widget.guestName}'
            : 'Changer la chambre de ${widget.guestName}',
      ),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: FutureBuilder<(List<AvailableRoom>, List<AvailableRoom>)>(
          future: _rooms,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final (memes, superieures) = snap.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!widget.surclassementSeulement) ...[
                  Text(
                    'Actuellement en chambre ${widget.currentRoomNumber}. '
                    'Chambres libres et propres de la même catégorie :',
                    style: legende,
                  ),
                  const SizedBox(height: 16),
                  if (memes.isEmpty)
                    Text(
                      'Aucune chambre libre et propre de cette catégorie.',
                      style: TextStyle(fontSize: 17, color: schema.error),
                    )
                  else
                    _puces(memes),
                  const SizedBox(height: 24),
                ],
                Text(
                  widget.surclassementSeulement
                      ? 'Chambre attribuée : ${widget.currentRoomNumber}. '
                            'Chambres libres et propres d’une catégorie '
                            'supérieure :'
                      : 'Surclassement, catégorie supérieure :',
                  style: legende,
                ),
                const SizedBox(height: 16),
                if (superieures.isEmpty)
                  Text(
                    'Aucune chambre libre dans une catégorie supérieure.',
                    style: TextStyle(fontSize: 17, color: schema.outline),
                  )
                else
                  _puces(superieures),
              ],
            );
          },
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

/// Le motif d'un surclassement, et s'il est offert ou payant.
///
/// Offert par defaut (decision du 14 octobre) : le tarif reserve reste.
/// Payant seulement pour qui a `reservation.manage` -- c'est un changement
/// de prix.
Future<Surclassement?> demanderSurclassement(
  BuildContext context, {
  required AvailableRoom chambre,
  required bool peutFacturer,
}) {
  return showDialog<Surclassement>(
    context: context,
    builder: (_) =>
        _SurclassementDialog(chambre: chambre, peutFacturer: peutFacturer),
  );
}

class _SurclassementDialog extends StatefulWidget {
  const _SurclassementDialog({
    required this.chambre,
    required this.peutFacturer,
  });

  final AvailableRoom chambre;
  final bool peutFacturer;

  @override
  State<_SurclassementDialog> createState() => _SurclassementDialogState();
}

class _SurclassementDialogState extends State<_SurclassementDialog> {
  final _motif = TextEditingController();
  bool _offert = true;

  @override
  void dispose() {
    _motif.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.chambre;
    final valide = _motif.text.trim().isNotEmpty;
    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.arrowFatUp, size: 30),
      title: Text('Surclasser en ${c.categorie ?? 'chambre ${c.number}'}'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Chambre ${c.number}'
              '${c.tarif == null ? '' : ', ${formatAmount(c.tarif!)} la nuit'}.',
              style: const TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: [
                const ButtonSegment(value: true, label: Text('Offert')),
                ButtonSegment(
                  value: false,
                  label: const Text('Payant'),
                  enabled: widget.peutFacturer,
                ),
              ],
              selected: {_offert},
              onSelectionChanged: (v) => setState(() => _offert = v.first),
            ),
            const SizedBox(height: 8),
            Text(
              _offert
                  ? 'Le client garde le tarif réservé.'
                  : 'Le tarif de la nouvelle catégorie s’applique aux nuits '
                        'pas encore portées.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            if (!widget.peutFacturer)
              Text(
                'Payant : réservé à un responsable, c’est un changement de '
                'prix.',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _motif,
              autofocus: true,
              maxLength: 255,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Motif',
                hintText: 'Standard en travaux, client fidèle…',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Retour'),
        ),
        FilledButton(
          onPressed: valide
              ? () => Navigator.of(context).pop(
                  Surclassement(
                    motif: _motif.text.trim(),
                    garderTarif: _offert,
                  ),
                )
              : null,
          child: const Text('Surclasser'),
        ),
      ],
    );
  }
}
