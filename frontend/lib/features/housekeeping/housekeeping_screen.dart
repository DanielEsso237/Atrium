/// Les chambres a faire (cahier des charges, F2.1-F2.2).
///
/// Cet ecran est utilise debout, souvent d'une seule main, parfois avec des
/// gants. D'ou des choix qui paraitraient grossiers ailleurs : un numero de
/// chambre enorme, un seul bouton par carte, et aucune navigation. La femme de
/// chambre n'a pas a chercher : ce qu'elle doit faire est en haut, ce qu'elle a
/// fait descend.
///
/// Les taches terminees restent visibles jusqu'au changement de journee plutot
/// que de disparaitre. Une chambre qui s'efface au moment ou on la valide
/// laisse toujours le doute d'avoir appuye a cote.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/housekeeping_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

class HousekeepingScreen extends ConsumerWidget {
  const HousekeepingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(cleaningJobsProvider);

    return ModuleScaffold(
      title: 'Chambres à faire',
      body: jobs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (liste) {
          if (liste.isEmpty) return const _RienAFaire();

          final aFaire = liste.where((j) => !j.faite).toList();
          final faites = liste.where((j) => j.faite).toList();

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (aFaire.isEmpty)
                const _RienAFaire()
              else
                for (final j in aFaire) _Carte(job: j),
              if (faites.isNotEmpty) ...[
                const SizedBox(height: 28),
                Text(
                  'FAIT AUJOURD\'HUI — ${faites.length}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 12),
                for (final j in faites) _Carte(job: j),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _RienAFaire extends StatelessWidget {
  const _RienAFaire();

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 72, color: schema.outline),
            const SizedBox(height: 20),
            Text(
              'Aucune chambre à faire.',
              style: TextStyle(fontSize: 20, color: schema.outline),
            ),
            const SizedBox(height: 8),
            Text(
              'Les départs de la journée apparaîtront ici.',
              style: TextStyle(fontSize: 16, color: schema.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _Carte extends ConsumerStatefulWidget {
  const _Carte({required this.job});

  final CleaningJob job;

  @override
  ConsumerState<_Carte> createState() => _CarteState();
}

class _CarteState extends ConsumerState<_Carte> {
  bool _busy = false;

  Future<void> _agir() async {
    final job = widget.job;
    setState(() => _busy = true);

    final depot = ref.read(housekeepingRepositoryProvider);
    final agent = ref.read(sessionProvider).agent?.id;

    try {
      if (job.enCours) {
        // Une chambre en cours a forcement une tache : c'est elle qui l'a
        // mise dans cet etat.
        await depot.finish(job.taskId!, by: agent);
      } else {
        // Sur la chambre et non sur la tache : elle peut ne pas en avoir, et
        // refuser de la nettoyer pour cette raison serait absurde.
        await depot.startRoom(job.roomId, by: agent);
      }
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    if (!mounted) return;
    setState(() => _busy = false);
    if (job.enCours) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Chambre ${job.roomNumber} propre et disponible.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final schema = Theme.of(context).colorScheme;

    final (Color couleur, String etat) = switch (job.roomStatus) {
      HousekeepingStatus.IN_PROGRESS => (
        CouleursEtat.nettoyage,
        'Nettoyage en cours',
      ),
      HousekeepingStatus.CLEAN || HousekeepingStatus.INSPECTED => (
        CouleursEtat.disponible,
        'Fait',
      ),
      HousekeepingStatus.DIRTY => (CouleursEtat.occupee, 'À faire'),
    };

    final texte = Theme.of(context).textTheme;
    final urgent =
        job.priority == Priority.URGENT || job.priority == Priority.HIGH;

    // Le numero d'abord, et en grand : c'est la seule information qu'elle
    // cherche en levant les yeux de son chariot.
    final numero = Text(
      job.roomNumber,
      style: texte.displaySmall?.copyWith(
        fontWeight: FontWeight.w800,
        fontFeatures: tabularFigures,
        color: job.faite ? schema.onSurfaceVariant : schema.onSurface,
      ),
    );

    final infos = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: couleur.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: couleur.withValues(alpha: 0.55)),
              ),
              child: Text(
                etat,
                style: texte.labelMedium?.copyWith(fontSize: 13),
              ),
            ),
            if (urgent)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.priority_high_rounded, size: 18, color: schema.error),
                  Text(
                    'Prioritaire',
                    style: texte.labelMedium?.copyWith(
                      fontSize: 13,
                      color: schema.error,
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(_detail(job), style: texte.bodySmall),
      ],
    );

    final Widget action = job.faite
        ? Icon(Icons.check_circle_rounded, size: 34, color: CouleursEtat.disponible)
        : SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: _busy ? null : _agir,
              icon: Icon(
                job.enCours ? Icons.check_rounded : Icons.play_arrow_rounded,
                size: 26,
              ),
              // « Marquer terminee » et non « Termine » : le second se lit
              // comme un etat deja atteint, et on croit avoir fini alors
              // qu'on vient seulement de commencer. Un bouton nomme par son
              // action, pas par son resultat.
              label: Text(job.enCours ? 'Marquer terminée' : 'Commencer'),
              style: job.enCours
                  ? FilledButton.styleFrom(
                      backgroundColor: CouleursEtat.disponible,
                      foregroundColor: AtriumColors.purpleNight,
                    )
                  : null,
            ),
          );

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder: (context, contraintes) => contraintes.maxWidth < 520
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        numero,
                        const SizedBox(width: 16),
                        Expanded(child: infos),
                        if (job.faite) action,
                      ],
                    ),
                    if (!job.faite) ...[const SizedBox(height: 14), action],
                  ],
                )
              : Row(
                  children: [
                    SizedBox(width: 120, child: numero),
                    Expanded(child: infos),
                    const SizedBox(width: 16),
                    action,
                  ],
                ),
        ),
      ),
    );
  }

  String _detail(CleaningJob job) {
    if (job.faite) {
      final d = job.durationMinutes;
      return d == null ? job.floorLabel : '${job.floorLabel} — $d min';
    }
    final ecoulees = job.minutesEcoulees;
    if (ecoulees != null) {
      return '${job.floorLabel} — commencé il y a $ecoulees min';
    }
    return job.floorLabel.isEmpty ? _typeLabel(job.type) : job.floorLabel;
  }

  String _typeLabel(HousekeepingTaskType? t) => switch (t) {
    null => 'À nettoyer',
    HousekeepingTaskType.DEPARTURE => 'Après départ',
    HousekeepingTaskType.STAYOVER => 'Client en place',
    HousekeepingTaskType.REFRESH => 'Rafraîchissement',
    HousekeepingTaskType.DEEP_CLEAN => 'Nettoyage complet',
    HousekeepingTaskType.INSPECTION => 'Contrôle',
  };
}
