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
import '../billing/payment_dialog.dart';
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

/// Ce que l'agent decide devant une ardoise non soldee.
enum _Depart { annuler, encaisser, partirQuandMeme }

/// Enregistre le depart apres confirmation.
Future<bool> confirmCheckOut(
  BuildContext context,
  WidgetRef ref, {
  required String lineId,
  required String guestName,
  required String roomNumber,
}) async {
  // Boucle et non question unique : apres un encaissement partiel il reste
  // quelque chose a demander, et on se retrouve devant le meme choix avec un
  // montant plus petit. Le client est au comptoir, il paie en deux fois, ca
  // arrive tous les jours.
  while (true) {
    // Le solde est lu ici plutot que passe par l'appelant : la liste des
    // reservations ne le connait pas, et il serait absurde d'obliger chaque
    // ecran a aller le chercher pour poser la meme question. Relu a chaque
    // tour, pour tenir compte de ce qui vient d'etre encaisse.
    final folio = await ref
        .read(folioRepositoryProvider)
        .openFolioForStay(lineId);
    final balance = folio?.balance ?? 0;

    if (!context.mounted) return false;

    if (balance <= 0) {
      final ok = await _confirm(
        context,
        title: 'Enregistrer le depart',
        message:
            '$guestName libere la chambre $roomNumber.\n\n'
            'La chambre repassera libre mais SALE : elle apparaitra dans la '
            'liste du housekeeping et dans la tuile « a nettoyer ».',
        action: 'Enregistrer le depart',
      );
      if (!ok) return false;
      break;
    }

    // Laisser partir un client qui doit encore de l'argent est irrattrapable.
    // Le montant exact s'affiche, et surtout on propose de le prendre : dire
    // « il reste 50 000 » sans offrir d'encaisser envoyait l'agent chercher
    // le module Factures pendant que le client attend.
    final decision = await _confirmerDepartNonSolde(
      context,
      guestName: guestName,
      roomNumber: roomNumber,
      balance: balance,
    );

    if (decision == _Depart.annuler) return false;
    if (decision == _Depart.partirQuandMeme) break;

    if (!context.mounted) return false;
    await showPaymentDialog(
      context,
      folioId: folio!.id,
      guestName: guestName,
      balance: balance,
    );
    // On repart au debut : le solde est relu, et la question se repose telle
    // qu'elle se pose vraiment maintenant.
  }

  if (!context.mounted) return false;

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

/// Le depart d'un client qui doit encore de l'argent.
///
/// Trois issues et non deux : renoncer, prendre l'argent, ou laisser partir en
/// connaissance de cause. La troisieme reste possible -- un client de passage,
/// une societe qui paiera sur facture -- mais elle n'est plus le seul chemin.
Future<_Depart> _confirmerDepartNonSolde(
  BuildContext context, {
  required String guestName,
  required String roomNumber,
  required int balance,
}) async {
  final schema = Theme.of(context).colorScheme;

  final decision = await showDialog<_Depart>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Ardoise non soldee'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$guestName libere la chambre $roomNumber.',
              style: const TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: schema.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reste a encaisser',
                    style: TextStyle(fontSize: 15, color: schema.onErrorContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatAmount(balance),
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: schema.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'La chambre repassera libre mais SALE.',
              style: TextStyle(fontSize: 15, color: schema.outline),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(_Depart.annuler),
          child: const Text('Annuler'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_Depart.partirQuandMeme),
          style: TextButton.styleFrom(foregroundColor: schema.error),
          child: const Text('Laisser partir sans payer'),
        ),
        // L'action attendue, donc la plus visible : neuf fois sur dix le
        // client est la et paie.
        FilledButton.icon(
          onPressed: () => Navigator.of(dialogContext).pop(_Depart.encaisser),
          icon: const Icon(Icons.payments_outlined),
          label: const Text('Encaisser'),
        ),
      ],
    ),
  );

  return decision ?? _Depart.annuler;
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
