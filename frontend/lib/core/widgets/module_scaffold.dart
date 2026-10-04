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

import '../../data/repositories/repository_providers.dart';
// L'ossature commune porte l'etat des echanges : c'est le seul endroit vu de
// tous les modules, donc le seul ou l'indicateur soit reellement permanent.
import '../../features/auth/session.dart';
import '../../features/sync/sync_status.dart';
import '../tokens.dart';
import '../ui/atrium_ui.dart';
import '../ui/icons.dart';

class ModuleScaffold extends ConsumerWidget {
  const ModuleScaffold({
    super.key,
    required this.title,
    required this.body,
    this.action,
    this.subtitle,
  });

  final String title;
  final Widget body;

  /// Une ligne sous le titre : ce que l'ecran compte ou resume (« 12 en
  /// cours, 3 attendues »). Le titre dit ou l'on est, elle dit ou l'on en est.
  final String? subtitle;

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

    // Sur telephone, l'action principale descend en bas, pleine largeur,
    // sous le pouce : dans l'en-tete elle ecrasait le titre.
    final largeur = MediaQuery.sizeOf(context).width;
    final etroit = largeur < 600;
    final marge = etroit ? 18.0 : 32.0;

    final entete = Padding(
      padding: EdgeInsets.fromLTRB(marge, etroit ? 16 : 30, marge, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: FadeUp(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: etroit ? 30 : 40,
                      fontWeight: FontWeight.w800,
                      letterSpacing: etroit ? -1 : -1.6,
                      height: 1.05,
                      color: AtriumColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: AtriumColors.textSecondary,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const PendingWritesBadge(),
          // Un metier a ecran unique ne passe jamais par le tableau de bord,
          // ou vit le bouton de deconnexion : sans celui-ci, la femme de
          // chambre etait prisonniere de sa liste. Sur une tablette que dix
          // agents se passent dans la journee, pouvoir rendre la main est la
          // premiere des choses.
          if (ecranUnique) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Se déconnecter',
              iconSize: 24,
              icon: const Icon(PhosphorIconsLight.signOut),
              onPressed: () => ref.read(sessionProvider.notifier).deconnecter(),
            ),
          ],
          if (action != null && !etroit) ...[
            const SizedBox(width: 14),
            FadeUp(index: 1, child: action!),
          ],
        ],
      ),
    );

    return Scaffold(
      // Le fond ambiant de la coque doit transparaitre.
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            entete,
            Expanded(child: body),
          ],
        ),
      ),
      bottomNavigationBar: action != null && etroit
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(width: double.infinity, child: action),
            )
          : null,
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
    // L'etat vient du dernier echange, pas de la connexion : sans quoi il
    // faudrait se reconnecter pour voir que le serveur est revenu. Tant
    // qu'aucun echange n'a rien appris, on retombe sur la connexion.
    final enLigne = sync.joignable ?? ref.watch(sessionProvider).online;
    final raison = sync.push?.detail;

    final (IconData icone, Color couleur, String message) = switch ((
      pending,
      sync.isBlocked,
      sync.isOffline,
    )) {
      (0, _, true) => (
        PhosphorIconsLight.cloudSlash,
        schema.onSurfaceVariant,
        'Serveur injoignable, mais rien n\'attend de remonter',
      ),
      (0, _, _) => (
        PhosphorIconsLight.cloudCheck,
        schema.onSurfaceVariant,
        'Tout est remonte au serveur',
      ),
      (_, true, _) => (
        PhosphorIconsLight.warningCircle,
        schema.error,
        'Une ecriture est refusee et bloque les $pending suivantes'
            '${raison == null ? '' : ' : $raison'}. Appuyer pour reessayer.',
      ),
      (_, _, true) => (
        PhosphorIconsLight.cloudSlash,
        schema.tertiary,
        '$pending ecriture(s) en attente — serveur injoignable. '
            'Elles repartiront toutes seules.',
      ),
      _ => (
        PhosphorIconsLight.cloudArrowUp,
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
          // L'etat en toutes lettres : une icone seule ne dit pas a l'agent
          // s'il travaille en ligne ou non.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icone, size: 22, color: couleur),
              const SizedBox(width: 6),
              Text(
                sync.isBlocked && pending > 0
                    ? 'Bloqué · $pending'
                    : pending > 0
                    ? '${enLigne ? 'En ligne' : 'Hors ligne'} · $pending'
                    : enLigne
                    ? 'En ligne'
                    : 'Hors ligne',
                style: TextStyle(
                  fontSize: 14,
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
