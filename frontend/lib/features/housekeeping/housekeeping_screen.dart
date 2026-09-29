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
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
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
    final liste = jobs.value ?? const <CleaningJob>[];
    final faites = liste.where((j) => j.faite).length;
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    return ModuleScaffold(
      title: 'Chambres à faire',
      subtitle: liste.isEmpty
          ? null
          : '$faites faite${faites > 1 ? 's' : ''} sur ${liste.length} '
                "aujourd'hui",
      body: jobs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: PhosphorIconsLight.warningCircle,
          title: 'Lecture impossible',
          message: '$e',
        ),
        data: (liste) {
          if (liste.isEmpty) return const _RienAFaire();

          final aFaire = liste.where((j) => !j.faite && !j.enCours).toList();
          final enCours = liste.where((j) => !j.faite && j.enCours).toList();
          final faites = liste.where((j) => j.faite).toList();

          return LayoutBuilder(
            builder: (context, c) {
              final progression = Padding(
                padding: EdgeInsets.fromLTRB(marge, 0, marge, 16),
                child: _Progression(
                  faites: faites.length,
                  enCours: enCours.length,
                  total: liste.length,
                ),
              );
              // Tablette posee et PC : trois colonnes, comme un tableau de
              // chariot. Une chambre glisse de gauche a droite dans la journee.
              if (c.maxWidth >= 900) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    progression,
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(marge, 0, marge, 20),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _Colonne(
                                titre: 'À faire',
                                couleur: CouleursEtat.occupee,
                                jobs: aFaire,
                                vide: 'Plus rien en attente.',
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: _Colonne(
                                titre: 'En cours',
                                couleur: CouleursEtat.nettoyage,
                                jobs: enCours,
                                vide: 'Aucune chambre commencée.',
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: _Colonne(
                                titre: 'Fait',
                                couleur: CouleursEtat.disponible,
                                jobs: faites,
                                vide: 'Les chambres terminées arrivent ici.',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }
              // Telephone : ce qu'elle doit faire en haut, ce qu'elle a fait
              // descend.
              return ListView(
                padding: EdgeInsets.fromLTRB(0, 0, 0, 32),
                children: [
                  progression,
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: marge),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (enCours.isEmpty && aFaire.isEmpty)
                          const _RienAFaire(),
                        for (final j in [...enCours, ...aFaire]) _Carte(job: j),
                        if (faites.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          Eyebrow("Fait aujourd'hui · ${faites.length}"),
                          const SizedBox(height: 12),
                          for (final j in faites) _Carte(job: j),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// La journee en une barre : fait, en cours, reste.
class _Progression extends StatelessWidget {
  const _Progression({
    required this.faites,
    required this.enCours,
    required this.total,
  });

  final int faites;
  final int enCours;
  final int total;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final part = total == 0 ? 0.0 : faites / total;
    return FadeUp(
      child: Bezel(
        core: p.hero,
        radius: 24,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Row(
          children: [
            Text(
              '${(part * 100).round()} %',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                color: p.heroAccent,
                fontFeatures: tabularFigures,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    total - faites == 0
                        ? 'Tout est propre. Belle journée.'
                        : '${total - faites} chambre${total - faites > 1 ? 's' : ''} '
                              'restante${total - faites > 1 ? 's' : ''}'
                              '${enCours > 0 ? ', dont $enCours en cours' : ''}',
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: p.onHero,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      height: 8,
                      child: Row(
                        children: [
                          if (faites > 0)
                            Expanded(
                              flex: faites,
                              child: Container(color: CouleursEtat.disponible),
                            ),
                          if (enCours > 0)
                            Expanded(
                              flex: enCours,
                              child: Container(color: CouleursEtat.nettoyage),
                            ),
                          if (total - faites - enCours > 0)
                            Expanded(
                              flex: total - faites - enCours,
                              child: Container(
                                color: p.onHero.withValues(alpha: 0.14),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Colonne extends StatelessWidget {
  const _Colonne({
    required this.titre,
    required this.couleur,
    required this.jobs,
    required this.vide,
  });

  final String titre;
  final Color couleur;
  final List<CleaningJob> jobs;
  final String vide;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Container(
      decoration: BoxDecoration(
        color: p.isDark
            ? Colors.white.withValues(alpha: 0.025)
            : p.night.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: couleur,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  titre,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: p.text,
                  ),
                ),
                const SizedBox(width: 8),
                Tag('${jobs.length}'),
              ],
            ),
          ),
          Expanded(
            child: jobs.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      vide,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13.5,
                        color: p.textSecondary,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    children: [
                      for (var i = 0; i < jobs.length; i++)
                        FadeUp(
                          index: i.clamp(0, 6),
                          child: _Carte(job: jobs[i], compacte: true),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _RienAFaire extends StatelessWidget {
  const _RienAFaire();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: PhosphorIconsLight.sparkle,
    title: 'Aucune chambre à faire',
    message: 'Les départs de la journée apparaîtront ici.',
  );
}

class _Carte extends ConsumerStatefulWidget {
  const _Carte({required this.job, this.compacte = false});

  final CleaningJob job;

  /// Dans une colonne du tableau : tout empile, pleine largeur.
  final bool compacte;

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
    final p = AtriumPalette.current;

    final (Color couleur, String etat) = switch (job.roomStatus) {
      HousekeepingStatus.IN_PROGRESS => (
        CouleursEtat.nettoyage,
        'Nettoyage en cours',
      ),
      HousekeepingStatus.CLEAN ||
      HousekeepingStatus.INSPECTED => (CouleursEtat.disponible, 'Fait'),
      HousekeepingStatus.DIRTY => (CouleursEtat.occupee, 'À faire'),
    };

    final urgent =
        job.priority == Priority.URGENT || job.priority == Priority.HIGH;

    // Le numero d'abord, et en grand : c'est la seule information qu'elle
    // cherche en levant les yeux de son chariot.
    final numero = Text(
      job.roomNumber,
      style: TextStyle(
        fontFamily: atriumFontFamily,
        fontSize: 40,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.6,
        height: 1,
        color: job.faite ? p.textSecondary : p.text,
        fontFeatures: tabularFigures,
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
            Tag(etat, color: couleur),
            if (urgent) Tag('Prioritaire', color: p.error, strong: true),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _detail(job),
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 13,
            color: p.textSecondary,
          ),
        ),
      ],
    );

    final Widget action = job.faite
        ? Icon(
            PhosphorIconsFill.checkCircle,
            size: 32,
            color: CouleursEtat.disponible,
          )
        : PillButton(
            // « Marquer terminee » et non « Termine » : le second se lit
            // comme un etat deja atteint, et on croit avoir fini alors
            // qu'on vient seulement de commencer. Un bouton nomme par son
            // action, pas par son resultat.
            label: job.enCours ? 'Marquer terminée' : 'Commencer',
            icon: job.enCours
                ? PhosphorIconsLight.check
                : PhosphorIconsLight.play,
            tone: job.enCours ? PillTone.accent : PillTone.primary,
            expand: widget.compacte,
            onPressed: _busy ? null : _agir,
          );

    // Pas de LayoutBuilder ici : la carte est mesuree par IntrinsicHeight.
    final empile = widget.compacte || MediaQuery.sizeOf(context).width < 600;
    final contenu = empile
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  numero,
                  const SizedBox(width: 14),
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
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      // Un bord colore a gauche : l'etat se lit meme du coin de l'oeil.
      // Pose en dessous d'un clip, car un bord non uniforme ne prend pas de
      // rayon.
      child: Container(
        decoration: BoxDecoration(
          color: p.paper,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(19),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: couleur),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: contenu,
                  ),
                ),
              ],
            ),
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
