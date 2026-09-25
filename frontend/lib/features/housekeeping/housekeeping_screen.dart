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
      title: 'Chambres a faire',
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
              'Aucune chambre a faire.',
              style: TextStyle(fontSize: 20, color: schema.outline),
            ),
            const SizedBox(height: 8),
            Text(
              'Les departs de la journee apparaitront ici.',
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
      HousekeepingStatus.DIRTY => (CouleursEtat.maintenance, 'A faire'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            // Le numero d'abord, et en grand : c'est la seule information
            // qu'elle cherche en levant les yeux de son chariot.
            SizedBox(
              width: 108,
              child: Text(
                job.roomNumber,
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  color: job.faite ? schema.outline : null,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: couleur,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(etat, style: const TextStyle(fontSize: 17)),
                      if (job.priority == Priority.URGENT ||
                          job.priority == Priority.HIGH) ...[
                        const SizedBox(width: 10),
                        Icon(
                          Icons.priority_high,
                          size: 20,
                          color: schema.error,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _detail(job),
                    style: TextStyle(fontSize: 15, color: schema.outline),
                  ),
                ],
              ),
            ),
            if (!job.faite)
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _agir,
                  icon: Icon(
                    job.enCours ? Icons.check : Icons.play_arrow,
                    size: 26,
                  ),
                  // « Marquer terminee » et non « Termine » : le second se
                  // lit comme un etat deja atteint, et on croit avoir fini
                  // alors qu'on vient seulement de commencer. Un bouton
                  // nomme par son action, pas par son resultat.
                  label: Text(
                    job.enCours ? 'Marquer terminee' : 'Commencer',
                    style: const TextStyle(fontSize: 17),
                  ),
                  style: job.enCours
                      ? FilledButton.styleFrom(
                          backgroundColor: CouleursEtat.disponible,
                        )
                      : null,
                ),
              )
            else
              Icon(Icons.check_circle, size: 32, color: CouleursEtat.disponible),
          ],
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
      return '${job.floorLabel} — commence il y a $ecoulees min';
    }
    return job.floorLabel.isEmpty ? _typeLabel(job.type) : job.floorLabel;
  }

  String _typeLabel(HousekeepingTaskType? t) => switch (t) {
    null => 'A nettoyer',
    HousekeepingTaskType.DEPARTURE => 'Apres depart',
    HousekeepingTaskType.STAYOVER => 'Client en place',
    HousekeepingTaskType.REFRESH => 'Rafraichissement',
    HousekeepingTaskType.DEEP_CLEAN => 'Nettoyage complet',
    HousekeepingTaskType.INSPECTION => 'Controle',
  };
}
