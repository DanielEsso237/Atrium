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
import '../../core/prolongation.dart';
import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import '../../data/repositories/repository_providers.dart';
import '../billing/payment_dialog.dart';
import '../guests/id_photos.dart';
import 'change_room_dialog.dart';
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
  final guestId = await ref
      .read(reservationRepositoryProvider)
      .guestIdOfLine(lineId);
  if (!context.mounted) return false;

  final ok = await _confirm(
    context,
    title: "Enregistrer l'arrivée",
    message:
        '$guestName va occuper la chambre $roomNumber.\n\n'
        "La chambre passera en occupée sur le plan, et son ardoise s'ouvre "
        'pour recevoir ses consommations.',
    action: "Enregistrer l'arrivée",
    // Le comptoir est le seul moment ou l'on a la piece en main. Les photos
    // ne bloquent pas l'arrivee pour autant : un client sans sa piece, ou
    // une tablette sans appareil photo, doit pouvoir etre installe.
    extra: guestId == null ? null : _PieceArrivee(guestId: guestId),
  );
  if (!ok) return false;

  await ref
      .read(reservationRepositoryProvider)
      .checkIn(lineId: lineId, by: ref.read(sessionProvider).agent?.id);

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$guestName est arrivé, chambre $roomNumber.')),
    );
  }
  return true;
}

/// Installe un client deja arrive dans une autre chambre.
///
/// Renvoie `true` si le changement a eu lieu.
Future<bool> confirmChangeRoom(
  BuildContext context,
  WidgetRef ref, {
  required String lineId,
  required String guestName,
  required String roomNumber,
}) async {
  final nouvelle = await pickRoomForChange(
    context,
    lineId: lineId,
    guestName: guestName,
    currentRoomNumber: roomNumber,
  );
  if (nouvelle == null || !context.mounted) return false;

  final ok = await _confirm(
    context,
    title: 'Changer de chambre',
    message:
        '$guestName quitte la chambre $roomNumber pour la ${nouvelle.number}.'
        '\n\n'
        'La $roomNumber redevient libre, sans passer par le menage : personne '
        'n\'y a dormi. L\'ardoise suit le client.',
    action: 'Changer de chambre',
  );
  if (!ok) return false;

  await ref
      .read(reservationRepositoryProvider)
      .changeRoom(
        lineId: lineId,
        roomId: nouvelle.id,
        by: ref.read(sessionProvider).agent?.id,
      );

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$guestName est maintenant en chambre ${nouvelle.number}.',
        ),
      ),
    );
  }
  return true;
}

/// Prolonge un sejour d'avance : la ligne « Prolongation » arrive tout de suite
/// sur l'ardoise.
///
/// Renvoie `true` si la prolongation a ete portee.
Future<bool> confirmExtendStay(
  BuildContext context,
  WidgetRef ref, {
  required String lineId,
  required String folioId,
  required String guestName,
}) async {
  final regles = await ref.read(settingsRepositoryProvider).stayRules();
  if (!context.mounted) return false;

  if (!regles.billsExtraHours) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "Fixez d'abord le prix de l'heure supplémentaire dans "
          "l'administration (Départ).",
        ),
      ),
    );
    return false;
  }

  final heures = await showDialog<int>(
    context: context,
    builder: (_) => _DialogProlongation(
      guestName: guestName,
      heureDepart: regles.checkoutHour,
      prixHeure: regles.extraHourPrice,
    ),
  );
  if (heures == null || !context.mounted) return false;

  try {
    await ref
        .read(folioRepositoryProvider)
        .addExtension(
          folioId: folioId,
          hours: heures,
          hourlyPrice: regles.extraHourPrice,
          stayLineId: lineId,
          postedBy: ref.read(sessionProvider).agent?.id,
        );
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Prolongation de $heures h portée à l’ardoise de $guestName.'),
      ),
    );
  }
  return true;
}

/// Le client part apres l'heure de depart : propose de facturer l'excedent.
///
/// Renvoie `false` si l'agent renonce au depart. Rien n'est propose -- et on
/// renvoie `true` -- quand le client part a l'heure, quand le prix de l'heure
/// n'est pas fixe, ou quand le sejour n'a pas d'ardoise ouverte.
Future<bool> _proposerProlongation(
  BuildContext context,
  WidgetRef ref, {
  required String lineId,
  required String guestName,
}) async {
  final folios = ref.read(folioRepositoryProvider);
  final folio = await folios.openFolioForStay(lineId);
  final regles = await ref.read(settingsRepositoryProvider).stayRules();
  final jourDepart = await ref
      .read(reservationRepositoryProvider)
      .departureDayOfLine(lineId);
  if (folio == null || jourDepart == null || !regles.billsExtraHours) {
    return true;
  }

  // Les heures deja demandees d'avance repoussent la limite : un client
  // prolonge de trois heures qui part a 14 h est parti a l'heure.
  final dejaPortees = await folios.extensionHours(folio.id);
  final limite = limiteDeDepart(
    jourDepart,
    heureDepart: regles.checkoutHour,
    heuresProlongees: dejaPortees,
  );
  final heures = heuresDeDepassement(DateTime.now(), limite);
  if (heures == 0) return true;
  if (!context.mounted) return false;

  final total = heures * regles.extraHourPrice;
  final decision = await showDialog<_Prolongation>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(PhosphorIconsLight.clockCountdown, size: 32),
      title: const Text('Départ après l’heure'),
      content: SizedBox(
        width: 460,
        child: Text(
          '$guestName devait partir à ${formatHeure(limite)}. '
          'Facturer $heures h de prolongation ?\n\n'
          '$heures × ${formatAmount(regles.extraHourPrice)} = '
          '${formatAmount(total)}',
          style: const TextStyle(fontSize: 17),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_Prolongation.annuler),
          child: const Text('Annuler'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_Prolongation.ignorer),
          child: const Text('Ne pas facturer'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_Prolongation.facturer),
          child: Text('Facturer $heures h'),
        ),
      ],
    ),
  );

  if (decision == null || decision == _Prolongation.annuler) return false;
  if (decision == _Prolongation.ignorer) return true;

  try {
    await folios.addExtension(
      folioId: folio.id,
      hours: heures,
      hourlyPrice: regles.extraHourPrice,
      stayLineId: lineId,
      postedBy: ref.read(sessionProvider).agent?.id,
    );
  } on StateError catch (e) {
    // Seuil de consommation depasse : le depart n'a pas eu lieu, l'agent
    // appelle son responsable.
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  }
  return true;
}

enum _Prolongation { annuler, ignorer, facturer }

/// Choix du nombre d'heures d'une prolongation demandee d'avance.
class _DialogProlongation extends StatefulWidget {
  const _DialogProlongation({
    required this.guestName,
    required this.heureDepart,
    required this.prixHeure,
  });

  final String guestName;
  final int heureDepart;
  final int prixHeure;

  @override
  State<_DialogProlongation> createState() => _DialogProlongationState();
}

class _DialogProlongationState extends State<_DialogProlongation> {
  int _heures = 1;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.clockCountdown, size: 32),
      title: const Text('Prolonger le séjour'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.guestName} garde la chambre au-delà de '
              '${widget.heureDepart} h.',
              style: const TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.outlined(
                  onPressed: _heures > 1
                      ? () => setState(() => _heures--)
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                const SizedBox(width: 20),
                Text(
                  '$_heures h',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 20),
                IconButton.outlined(
                  onPressed: _heures < 12
                      ? () => setState(() => _heures++)
                      : null,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '$_heures × ${formatAmount(widget.prixHeure)} = '
              '${formatAmount(_heures * widget.prixHeure)}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: schema.onSurfaceVariant),
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
          onPressed: () => Navigator.of(context).pop(_heures),
          child: const Text('Ajouter à l’ardoise'),
        ),
      ],
    );
  }
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
  // Parti apres l'heure de depart : la prolongation se propose AVANT de lire
  // le solde, sinon l'agent encaisserait une note qui change juste apres.
  if (!await _proposerProlongation(
    context,
    ref,
    lineId: lineId,
    guestName: guestName,
  )) {
    return false;
  }
  if (!context.mounted) return false;

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
        title: 'Enregistrer le départ',
        message:
            '$guestName libère la chambre $roomNumber.\n\n'
            'La chambre repassera libre mais sale : elle apparaîtra dans la '
            'liste du ménage et dans la tuile « à nettoyer ».',
        action: 'Enregistrer le départ',
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
        content: Text('$guestName est parti, chambre $roomNumber à nettoyer.'),
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
      icon: const Icon(PhosphorIconsLight.warningCircle, size: 32),
      title: const Text('Ardoise non soldée'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$guestName libère la chambre $roomNumber.',
              style: const TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: schema.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: schema.error.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reste à encaisser',
                    style: TextStyle(fontSize: 15, color: schema.onSurface),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatAmount(balance),
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1,
                      color: schema.error,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'La chambre repassera libre, mais sale.',
              style: TextStyle(fontSize: 15, color: schema.onSurfaceVariant),
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
          icon: const Icon(PhosphorIconsLight.coins, size: 20),
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
  Widget? extra,
}) async {
  final schema = Theme.of(context).colorScheme;

  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(
        danger ? PhosphorIconsLight.warningCircle : PhosphorIconsLight.signIn,
        size: 32,
      ),
      title: Text(title),
      scrollable: extra != null,
      content: SizedBox(
        width: 460,
        child: extra == null
            ? Text(message, style: const TextStyle(fontSize: 17))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message, style: const TextStyle(fontSize: 17)),
                  extra,
                ],
              ),
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

class _PieceArrivee extends StatelessWidget {
  const _PieceArrivee({required this.guestId});

  final String guestId;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 22),
        Text(
          "Pièce d'identité",
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: p.text,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Photographiez le recto et le verso, maintenant ou plus tard '
          'depuis la fiche client.',
          style: TextStyle(fontSize: 14, color: p.textSecondary),
        ),
        const SizedBox(height: 12),
        IdPhotoPair(guestId: guestId),
      ],
    );
  }
}

/// Annule une reservation, apres confirmation et un motif facultatif.
///
/// Le dialogue dit d'avance ce que deviennent les arrhes deja encaissees :
/// elles restent a l'hotel. L'agent ne doit pas le decouvrir apres coup,
/// devant un client qui demande a etre rembourse.
Future<bool> confirmCancelReservation(
  BuildContext context,
  WidgetRef ref, {
  required String reservationId,
  required String guestName,
  required String reference,
}) async {
  final repo = ref.read(reservationRepositoryProvider);
  final arrhes = await repo.keptDeposit(reservationId);
  if (!context.mounted) return false;

  final motif = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(PhosphorIconsLight.warningCircle, size: 32),
      title: const Text('Annuler la réservation'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Le dossier $reference de $guestName sera annulé, et sa chambre '
              'libérée.',
              style: const TextStyle(fontSize: 17),
            ),
            if (arrhes != null) ...[
              const SizedBox(height: 12),
              Text(
                'Les arrhes encaissées (${formatAmount(arrhes)}) restent '
                "acquises à l'hôtel : elles ne sont pas remboursées.",
                style: const TextStyle(fontSize: 16),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: motif,
              maxLength: 255,
              decoration: const InputDecoration(
                labelText: 'Motif (facultatif)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Garder la réservation'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          child: const Text('Annuler la réservation'),
        ),
      ],
    ),
  );
  final raison = motif.text;
  motif.dispose();
  if (ok != true || !context.mounted) return false;

  try {
    await repo.cancel(
      reservationId: reservationId,
      reason: raison,
      by: ref.read(sessionProvider).agent?.id,
    );
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  }
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Réservation $reference annulée.')));
  }
  return true;
}
