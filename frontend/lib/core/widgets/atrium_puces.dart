/// Les pastilles des bandeaux : l'etat de la connexion, les ecritures en
/// attente, et la pastille nue qui les porte.
///
/// Partagees par tous les ecrans refondus : un agent doit lire l'etat de la
/// tablette au meme endroit, avec les memes mots, quel que soit l'ecran ou il
/// se trouve.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/outbox_sender.dart';
import '../../data/repositories/repository_providers.dart';
import '../../features/auth/session.dart';
import '../../features/sync/sync_status.dart';
import '../tokens.dart';

/// Une pastille du bandeau.
class AtriumPuce extends StatelessWidget {
  AtriumPuce({
    super.key,
    required this.icone,
    this.child,
    Color? fond,
    Color? encre,
    this.onTap,
  }) : fond = fond ?? AtriumColors.white,
       encre = encre ?? AtriumDashColors.title;

  final IconData icone;

  /// Le texte de la pastille ; `null` pour l'icone seule.
  final Widget? child;
  final Color fond;
  final Color encre;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(AtriumRadii.md),
        boxShadow: fond == AtriumColors.white ? AtriumShadows.soft : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AtriumRadii.md),
          child: Container(
            constraints: const BoxConstraints(minHeight: 42),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icone, size: 20, color: encre),
                if (child != null) ...[
                  const SizedBox(width: AtriumSpacing.sm),
                  DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: encre,
                    ),
                    child: child!,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dire honnetement ou en est la tablette. L'etat vient du dernier echange,
/// pas de la connexion : sinon un agent devrait se deconnecter et se
/// reconnecter pour que l'application remarque que le serveur est revenu, ce
/// que personne ne fera en service. Tant qu'aucun echange n'a rien appris, on
/// retombe sur ce que disait l'authentification.
class PuceEtatConnexion extends ConsumerWidget {
  const PuceEtatConnexion({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final enLigne = ref.watch(syncProvider).joignable ?? session.online;

    return Tooltip(
      message: enLigne
          ? 'Dernier échange avec le serveur : réussi'
          : 'Serveur injoignable : la tablette travaille seule et garde ses '
                'écritures',
      child: AtriumPuce(
        icone: enLigne ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
        fond: AtriumDashColors.chipMint,
        encre: AtriumDashColors.chipMintInk,
        child: Text(enLigne ? 'En ligne' : 'Hors ligne'),
      ),
    );
  }
}

/// Les ecritures qui attendent de remonter. Absente quand tout est remonte :
/// la pastille d'etat dit deja l'essentiel.
///
/// **Et on peut appuyer dessus.** La remontee se fait toute seule, mais quand
/// elle est bloquee ou que les tentatives se sont espacees, l'agent qui vient
/// de rebrancher le cable veut pouvoir forcer sans attendre. Le renvoi est
/// idempotent cote serveur : appuyer dix fois ne cree pas dix lignes.
class PuceEcritures extends ConsumerWidget {
  const PuceEcritures({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attente = ref.watch(pendingWritesProvider).value ?? 0;
    final sync = ref.watch(syncProvider);
    if (attente == 0) return const SizedBox.shrink();

    final bloque = sync.isBlocked;
    // La raison du refus : sans elle, l'agent sait que ca bloque mais pas
    // quoi corriger.
    final raison = sync.push?.detail;
    final message = bloque
        ? 'Une écriture est refusée et bloque les $attente suivantes'
              '${raison == null ? '' : ' : $raison'}. Appuyer pour réessayer.'
        : sync.isOffline
        ? '$attente écriture(s) en attente, serveur injoignable. '
              'Elles repartiront toutes seules.'
        : '$attente écriture(s) en cours de remontée';

    return Tooltip(
      message: message,
      child: AtriumPuce(
        icone: bloque ? Icons.error_outline : Icons.cloud_upload_outlined,
        encre: bloque ? AtriumColors.error : AtriumDashColors.title,
        onTap: () => ref.read(syncSchedulerProvider.notifier).maintenant(),
        // Le nombre seul : le detail est dans l'info-bulle. Longue, la
        // pastille repoussait le sous-titre de l'accueil sur deux lignes.
        child: Text(bloque ? 'Bloqué ($attente)' : '$attente'),
      ),
    );
  }
}

/// Le bouton carre blanc des bandeaux (retour, menu) : 44 points, coins
/// arrondis, voile d'ombre, comme les pastilles a cote desquelles il se pose.
class AtriumBoutonCarre extends StatelessWidget {
  const AtriumBoutonCarre({
    super.key,
    required this.icone,
    required this.libelle,
    required this.onTap,
  });

  final IconData icone;
  final String libelle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rayon = BorderRadius.circular(AtriumRadii.md);
    return Tooltip(
      message: libelle,
      waitDuration: const Duration(milliseconds: 500),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AtriumColors.white,
          borderRadius: rayon,
          boxShadow: AtriumShadows.soft,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: rayon,
            child: SizedBox.square(
              dimension: 44,
              child: Icon(icone, size: 22, color: AtriumDashColors.title),
            ),
          ),
        ),
      ),
    );
  }
}

/// Echange avec le serveur, a la demande : on remonte, puis on rapatrie.
///
/// Un bouton en plus de la remontee automatique : la reception doit
/// pouvoir decider quand elle echange, et surtout voir si ca a marche.
/// Present sur tous les ecrans, pas seulement le plan des chambres.
class BoutonSynchroniser extends ConsumerWidget {
  const BoutonSynchroniser({super.key, this.compact = false});

  /// Sur un telephone, l'icone seule : le libelle passe en info-bulle.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);

    return Tooltip(
      message: 'Échanger avec le serveur',
      child: AtriumPuce(
        icone: Icons.sync_rounded,
        onTap: sync.running
            ? null
            : () async {
                await ref.read(syncProvider.notifier).refresh();
                if (!context.mounted) return;

                final etat = ref.read(syncProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(_resume(etat)),
                    // Une file bloquee ne se resout pas toute seule : elle
                    // reste affichee le temps d'etre lue, en rouge,
                    // contrairement au reste.
                    duration: etat.isBlocked
                        ? const Duration(seconds: 10)
                        : const Duration(seconds: 4),
                    backgroundColor: etat.isBlocked ? AtriumColors.error : null,
                  ),
                );
              },
        child: sync.running
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AtriumDashColors.title,
                ),
              )
            : (compact ? null : const Text('Synchroniser')),
      ),
    );
  }
}

/// Ce que l'echange a donne, en une phrase pour la reception.
///
/// Les deux sens y figurent, et dans cet ordre : ce qui est parti compte plus
/// que ce qui est arrive. Un receptionniste qui a enregistre six arrivees hors
/// ligne veut d'abord savoir qu'elles sont remontees.
String _resume(SyncUiState etat) {
  final push = etat.push;
  final pull = etat.last;

  if (push != null && push.arret == DrainStop.bloque) {
    return 'Une écriture est refusée par le serveur et bloque les suivantes : '
        '${push.detail}';
  }
  if (push != null && push.arret == DrainStop.sessionInvalide) {
    return 'Session expirée : reconnectez-vous pour remonter les écritures.';
  }

  final monte = push?.envoyees ?? 0;
  final remonte = monte == 0
      ? null
      : '$monte écriture${monte > 1 ? 's' : ''} remontée${monte > 1 ? 's' : ''}';

  if (pull == null || pull.offline) {
    return remonte == null
        ? 'Serveur injoignable : l’écran garde les données de la tablette.'
        : '$remonte, puis le serveur a cessé de répondre.';
  }
  if (!pull.succeeded) {
    return 'Échec : ${pull.error}';
  }

  // Les chambres et les donnees metier descendent ensemble ; on annonce le
  // total, parce que c'est « la tablette a-t-elle rattrape le serveur » que
  // la reception veut savoir, pas le detail par table.
  final metier = etat.pull?.total ?? 0;
  final descendu = metier == 0
      ? '${pull.rooms} chambres rapatriées'
      : '${pull.rooms + metier} lignes rapatriées';

  final ecartees = etat.pull?.skipped ?? 0;
  final reserve = ecartees == 0
      ? ''
      : ', $ecartees ligne${ecartees > 1 ? 's' : ''} épargnée'
            '${ecartees > 1 ? 's' : ''}, pas encore remontée'
            '${ecartees > 1 ? 's' : ''}';

  return remonte == null
      ? '$descendu$reserve.'
      : '$remonte, $descendu$reserve.';
}

/// L'etat de l'echange avec le serveur, tel que tous les ecrans le montrent :
/// en ligne ou non, les ecritures qui attendent, et le bouton pour echanger.
///
/// Un seul composant : le plan des chambres avait le bouton, les autres
/// ecrans un simple badge, et l'agent ne savait pas ou synchroniser.
class BarreSynchronisation extends StatelessWidget {
  const BarreSynchronisation({super.key, this.compact = false});

  /// Sur un ecran etroit : sans la pastille d'etat, bouton sans libelle.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AtriumSpacing.sm,
      runSpacing: AtriumSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!compact) const PuceEtatConnexion(),
        const PuceEcritures(),
        BoutonSynchroniser(compact: compact),
      ],
    );
  }
}
