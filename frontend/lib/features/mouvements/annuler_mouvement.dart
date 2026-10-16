/// Defaire un mouvement de la chronologie, sur le code d'un responsable.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/queries/access_queries.dart';
import '../../data/local/queries/mouvements_queries.dart';
import '../annulations/accord_responsable.dart';

/// L'agent peut-il proposer d'annuler ce mouvement ? Le geste lui-meme
/// demandera toujours le code d'un responsable : ce droit-ci est celui de
/// faire l'ecriture, comme pour le geste d'origine.
bool peutProposerAnnulation(AccessProfile acces, Mouvement m) {
  if (!m.annulable) return false;
  return switch (m.genre) {
    GenreMouvement.arrivee ||
    GenreMouvement.depart => m.lineId != null && acces.peut('reservation.manage'),
    GenreMouvement.encaissement =>
      m.paymentId != null && acces.peut('cash.session'),
    _ => false,
  };
}

Future<void> annulerMouvement(
  BuildContext context,
  WidgetRef ref,
  Mouvement m,
) async {
  switch (m.genre) {
    case GenreMouvement.arrivee:
      await annulerArrivee(
        context,
        ref,
        lineId: m.lineId!,
        guestName: m.client ?? 'Le client',
        roomNumber: m.chambre,
      );
    case GenreMouvement.depart:
      await annulerDepart(
        context,
        ref,
        lineId: m.lineId!,
        guestName: m.client ?? 'Le client',
        roomNumber: m.chambre,
      );
    case GenreMouvement.encaissement:
      await annulerEncaissement(
        context,
        ref,
        paymentId: m.paymentId!,
        amount: m.montant ?? 0,
        quoi: m.client ?? m.reference ?? 'client de passage',
      );
    default:
      break;
  }
}
