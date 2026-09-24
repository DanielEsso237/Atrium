/// Arrivee et depart d'un sejour (cahier des charges, F1.2).
///
/// Les deux operations vivent ici et sont appelees des deux ecrans qui en ont
/// besoin : la liste des reservations et la fiche de chambre du plan. Un
/// receptionniste fait un check-in depuis la liste du matin ; un autre le fait
/// en cliquant sur la chambre. Les deux doivent aboutir au meme endroit, avec
/// la meme confirmation.
///
/// Ce sont des ecritures irreversibles par l'interface — on ne « defait » pas
/// une arrivee — donc chacune demande confirmation, avec ce qu'elle va
/// changer ecrit noir sur blanc.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

/// Enregistre l'arrivee apres confirmation.
///
/// Renvoie `true` si l'operation a eu lieu.
Future<bool> confirmCheckIn(
  BuildContext context,
  WidgetRef ref, {
  required String lineId,
  required String guestName,
  required String roomNumber,
}) async {
  final ok = await _confirm(
    context,
    title: 'Enregistrer l\'arrivee',
    message:
        '$guestName va occuper la chambre $roomNumber.\n\n'
        'La chambre passera en occupee sur le plan, et son ardoise s\'ouvre '
        'pour recevoir ses consommations.',
    action: 'Enregistrer l\'arrivee',
  );
  if (!ok) return false;

  await ref
      .read(reservationRepositoryProvider)
      .checkIn(lineId: lineId, by: ref.read(sessionProvider).agent?.id);

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$guestName est arrive — chambre $roomNumber.')),
    );
  }
  return true;
}

/// Enregistre le depart apres confirmation.
Future<bool> confirmCheckOut(
  BuildContext context,
  WidgetRef ref, {
  required String lineId,
  required String guestName,
  required String roomNumber,
}) async {
  // Le solde est lu ici plutot que passe par l'appelant : la liste des
  // reservations ne le connait pas, et il serait absurde d'obliger chaque
  // ecran a aller le chercher pour poser la meme question.
  final folio = await ref
      .read(folioRepositoryProvider)
      .openFolioForStay(lineId);
  final balance = folio?.balance ?? 0;

  if (!context.mounted) return false;

  final ok = await _confirm(
    context,
    title: 'Enregistrer le depart',
    message: [
      '$guestName libere la chambre $roomNumber.',
      '',
      'La chambre repassera libre mais SALE : elle apparaitra dans la liste '
          'du housekeeping et dans la tuile « a nettoyer ».',
      // Laisser partir un client qui doit encore de l'argent est
      // irrattrapable : le montant exact s'affiche, pas un vague avertissement.
      if (balance > 0) ...[
        '',
        'ATTENTION : il reste ${formatAmount(balance)} a encaisser.',
      ],
    ].join('\n'),
    action: balance > 0 ? 'Laisser partir quand meme' : 'Enregistrer le depart',
    danger: balance > 0,
  );
  if (!ok) return false;

  await ref
      .read(reservationRepositoryProvider)
      .checkOut(lineId: lineId, by: ref.read(sessionProvider).agent?.id);

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$guestName est parti — chambre $roomNumber a nettoyer.'),
      ),
    );
  }
  return true;
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
  bool danger = false,
}) async {
  final schema = Theme.of(context).colorScheme;

  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 460,
        child: Text(message, style: const TextStyle(fontSize: 17)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: danger
              ? FilledButton.styleFrom(backgroundColor: schema.error)
              : null,
          child: Text(action),
        ),
      ],
    ),
  );

  return answer ?? false;
}
