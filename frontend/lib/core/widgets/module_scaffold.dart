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
// L'ossature commune porte l'etat des echanges : c'est le seul endroit vu de
// tous les modules, donc le seul ou l'indicateur soit reellement permanent.
import '../../features/auth/session.dart';
import '../../features/sync/sync_status.dart';

class ModuleScaffold extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    // Un metier a ecran unique n'a nulle part ou revenir : lui montrer une
    // fleche retour, c'est lui promettre un ailleurs qui n'existe pas. Le
    // routeur le renverrait ici aussitot.
    final accueil = ref.watch(sessionProvider).acces.homeRoute;
    final ecranUnique = accueil != null && accueil != '/';

    return Scaffold(
      appBar: AppBar(
        leading: ecranUnique
            ? null
            : IconButton(
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
///
/// **Et on peut appuyer dessus.** La remontee se fait toute seule, mais quand
/// elle est bloquee ou que les tentatives se sont espacees, l'agent qui vient
/// de rebrancher le cable veut pouvoir forcer sans attendre. L'objet qui
/// montre le probleme est celui sur lequel on appuie pour le regler.
class PendingWritesBadge extends ConsumerWidget {
  const PendingWritesBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingWritesProvider).value ?? 0;
    final sync = ref.watch(syncProvider);
    final schema = Theme.of(context).colorScheme;

    final (IconData icone, Color couleur, String message) = switch ((
      pending,
      sync.isBlocked,
      sync.isOffline,
    )) {
      (0, _, true) => (
        Icons.cloud_off_outlined,
        schema.outline,
        'Serveur injoignable, mais rien n\'attend de remonter',
      ),
      (0, _, _) => (
        Icons.cloud_done_outlined,
        schema.outline,
        'Tout est remonte au serveur',
      ),
      (_, true, _) => (
        Icons.error_outline,
        schema.error,
        'Une ecriture est refusee et bloque les $pending suivantes. '
            'Appuyer pour reessayer.',
      ),
      (_, _, true) => (
        Icons.cloud_off_outlined,
        schema.tertiary,
        '$pending ecriture(s) en attente — serveur injoignable. '
            'Elles repartiront toutes seules.',
      ),
      _ => (
        Icons.cloud_upload_outlined,
        schema.tertiary,
        '$pending ecriture(s) en cours de remontee',
      ),
    };

    return Tooltip(
      message: message,
      child: InkWell(
        // Forcer un essai est sans danger : le renvoi est idempotent cote
        // serveur, appuyer dix fois ne cree pas dix lignes.
        onTap: () => ref.read(syncSchedulerProvider.notifier).maintenant(),
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: pending == 0
              ? Icon(icone, size: 24, color: couleur)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icone, size: 22, color: couleur),
                    const SizedBox(width: 6),
                    Text(
                      '$pending',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: couleur,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
