/// Les tablettes de l'hotel, et celles dont la file d'envoi est bloquee.
///
/// Un refus du serveur bloque la file d'une tablette, avec tout ce qui
/// attend derriere ; il ne se voyait que sur la tablette elle-meme. Ici,
/// l'administration et la direction (`sync.monitor`) voient de n'importe
/// quel poste quelle tablette est bloquee, sur quelle saisie, de quel agent,
/// et combien d'ecritures attendent derriere. Le meme contenu forme l'onglet
/// Tablettes de l'administration.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/tablettes_queries.dart';

final tablettesProvider = StreamProvider<List<TabletteSuivie>>(
  (ref) => ref.watch(databaseProvider).watchTablettes(),
);

class TablettesScreen extends StatelessWidget {
  const TablettesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ModuleScaffold(
      title: 'Tablettes',
      subtitle: 'Ce qui ne remonte plus, et pourquoi',
      body: TablettesSection(),
    );
  }
}

class TablettesSection extends ConsumerWidget {
  const TablettesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(tablettesProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Lecture impossible : $e')),
          data: (tablettes) => tablettes.isEmpty
              ? const EmptyState(
                  icon: PhosphorIconsLight.deviceMobile,
                  title: 'Aucune tablette connue',
                  message:
                      'Une tablette apparaît ici à sa première connexion en '
                      'ligne.',
                )
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    for (final t in tablettes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _CarteTablette(tablette: t),
                      ),
                  ],
                ),
        );
  }
}

/// `26/10 à 14 h 05`, a l'heure de la tablette.
String _moment(DateTime instant) {
  final l = instant.toLocal();
  final mm = l.minute.toString().padLeft(2, '0');
  return '${formatShortDate(l).substring(0, 5)} à ${l.hour} h $mm';
}

class _CarteTablette extends StatelessWidget {
  const _CarteTablette({required this.tablette});

  final TabletteSuivie tablette;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final t = tablette;
    final ouverts = t.blocages.where((b) => b.ouvert).toList();
    final leves = t.blocages.where((b) => !b.ouvert).toList();
    return Bezel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                PhosphorIconsLight.deviceMobile,
                color: t.bloquee ? p.error : p.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.estCelleCi ? '${t.nom} (cette tablette)' : t.nom,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              ),
              Text(
                t.bloquee ? 'Bloquée' : 'Rien de bloqué',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: t.bloquee ? p.error : p.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (t.vueLe case final v?) 'Vue le ${_moment(v)}',
              if (t.version case final v?) 'version $v',
            ].join(' · ').ifEmpty('Pas encore vue en ligne'),
            style: TextStyle(fontSize: 13, color: p.textSecondary),
          ),
          for (final b in ouverts) ...[
            const SizedBox(height: 12),
            _LigneBlocage(blocage: b),
          ],
          if (leves.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Eyebrow('Levés cette semaine'),
            for (final b in leves) ...[
              const SizedBox(height: 6),
              _LigneBlocage(blocage: b),
            ],
          ],
        ],
      ),
    );
  }
}

class _LigneBlocage extends StatelessWidget {
  const _LigneBlocage({required this.blocage});

  final BlocageVu blocage;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final b = blocage;
    final titre = [
      b.quoi,
      if (b.montant case final m?) formatAmount(m),
      if (b.auteur case final a?) 'saisi par $a',
    ].join(' · ');
    final details = b.ouvert
        ? [
            b.raison?.trim().ifEmpty('Refus sans motif') ?? 'Refus sans motif',
            'bloquée depuis le ${_moment(b.bloqueLe)}',
            switch (b.derriere) {
              0 => 'rien n’attend derrière',
              1 => '1 saisie attend derrière',
              final n => '$n saisies attendent derrière',
            },
          ]
        : [
            b.resolution == 'SENT' ? 'Passée' : 'Retirée de la file',
            if (b.leveLe case final l?) 'le ${_moment(l)}',
          ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: b.ouvert ? p.errorTint : p.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titre,
            style: TextStyle(fontWeight: FontWeight.w600, color: p.text),
          ),
          const SizedBox(height: 2),
          Text(
            details.join(' · '),
            style: TextStyle(fontSize: 13, color: p.textSecondary),
          ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String autre) => isEmpty ? autre : this;
}
