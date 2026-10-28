/// Envoyer les ecritures d'un collegue absent, sur le code d'un responsable
/// (correction 8).
///
/// La pastille « 1 · RECEP01 » disait seulement qu'elles attendaient. Un
/// agent qui ne repasse pas les laissait pour toujours : un responsable les
/// envoie maintenant a sa place, en ligne, et le serveur garde la trace de
/// qui l'a permis.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/autorisation_repository.dart';
import '../../data/repositories/envoi_pour_autrui.dart';
import '../../data/repositories/repository_providers.dart';
import '../annulations/accord_responsable.dart';

/// Propose d'envoyer les ecritures d'un des collegues de [autrui].
Future<void> envoyerPourUnAbsent(
  BuildContext context,
  WidgetRef ref,
  List<({String id, String agent, int n})> autrui,
) async {
  final choisi = autrui.length == 1
      ? autrui.single
      : await showDialog<({String id, String agent, int n})>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Écritures en attente de leur auteur'),
            children: [
              for (final a in autrui)
                SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(a),
                  child: Text('${a.agent} · ${_ecritures(a.n)}'),
                ),
            ],
          ),
        );
  if (choisi == null || !context.mounted) return;

  EnvoiDelegue? resultat;
  final accord = await demanderAccordResponsable(
    context,
    titre: 'Envoyer à la place de ${choisi.agent}',
    explication:
        '${_ecritures(choisi.n)} de ${choisi.agent} attendent sa connexion '
        'sur cette tablette. Un responsable peut les envoyer à sa place : '
        'elles partent avec les droits de ${choisi.agent}, et le serveur '
        'garde la trace de qui l’a permis.',
    libelleValider: 'Envoyer',
    verifier: (code, secret, motif) async {
      resultat = await ref
          .read(envoiPourAutruiProvider)
          .envoyer(
            auteurId: choisi.id,
            code: code,
            secret: secret,
            motif: motif,
          );
      return Responsable(id: '', nom: resultat!.responsable);
    },
  );
  final r = resultat;
  if (accord == null || r == null || !context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(messageEnvoiDelegue(choisi.agent, r))));
}

/// Ce que l'agent lit apres l'envoi.
String messageEnvoiDelegue(String agent, EnvoiDelegue r) {
  final envoyees = r.envoyees == 0
      ? 'Aucune écriture de $agent envoyée'
      : '${_ecritures(r.envoyees)} de $agent envoyée${r.envoyees > 1 ? 's' : ''}';
  final qui = r.responsable.isEmpty ? '' : ', autorisé par ${r.responsable}';
  if (r.refus != null) {
    return '$envoyees$qui. ${_ecritures(r.restantes)} reste'
        '${r.restantes > 1 ? 'nt' : ''} : ${r.refus}';
  }
  return '$envoyees$qui.';
}

String _ecritures(int n) => n > 1 ? '$n écritures' : '$n écriture';
