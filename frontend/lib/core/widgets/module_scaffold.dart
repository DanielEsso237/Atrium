/// Ossature commune a tous les ecrans de module.
///
/// Les six modules du paragraphe 5.1 — reception, restaurant, maintenance,
/// housekeeping, clients, factures — partagent le meme cadre : un retour vers
/// le tableau de bord, un titre, l'indicateur d'ecritures en attente, et une
/// action principale a droite.
///
/// Le mettre ici plutot que de le recopier dans chaque ecran evite qu'un
/// module finisse par avoir son bouton retour a un endroit different des cinq
/// autres — ce qui, sur une tablette qu'on utilise sans regarder, compte plus
/// que sur un ecran de bureau.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/repository_providers.dart';

class ModuleScaffold extends StatelessWidget {
  const ModuleScaffold({
    super.key,
    required this.title,
    required this.body,
    this.action,
  });

  final String title;
  final Widget body;

  /// Action principale du module, a droite du titre : « Nouveau client »,
  /// « Nouvelle reservation »…
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          iconSize: 28,
          tooltip: 'Tableau de bord',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: Text(title),
        actions: [
          const PendingWritesBadge(),
          if (action != null) ...[
            const SizedBox(width: 12),
            action!,
          ],
          const SizedBox(width: 16),
        ],
      ),
      body: body,
    );
  }
}

/// Combien d'ecritures attendent de remonter au serveur.
///
/// Visible en permanence, et volontairement discret quand la file est vide.
/// Un receptionniste doit pouvoir constater qu'il travaille hors ligne au
/// moment ou ca arrive, pas le decouvrir en fin de service.
class PendingWritesBadge extends ConsumerWidget {
  const PendingWritesBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingWritesProvider).value ?? 0;
    final schema = Theme.of(context).colorScheme;

    if (pending == 0) {
      return Tooltip(
        message: 'Tout est remonte au serveur',
        child: Icon(Icons.cloud_done_outlined, size: 24, color: schema.outline),
      );
    }

    return Tooltip(
      message: '$pending ecriture(s) en attente de remontee',
      child: Chip(
        avatar: const Icon(Icons.cloud_upload_outlined, size: 20),
        label: Text('$pending'),
        backgroundColor: schema.tertiaryContainer,
      ),
    );
  }
}
