/// Les tablettes de l'hotel, et celles dont la file d'envoi est bloquee.
///
/// Un refus du serveur bloque la file d'une tablette, avec tout ce qui
/// attend derriere ; il ne se voyait que sur la tablette elle-meme. Ici,
/// l'administration et la direction (`sync.monitor`) voient de n'importe
/// quel poste quelle tablette est bloquee, sur quelle saisie, de quel agent,
/// et combien d'ecritures attendent derriere. Le meme contenu forme l'onglet
/// Tablettes de l'administration.
///
/// Et ils peuvent l'**abandonner** (correction 6), quand la tablette bloquee
/// le permet : la decision part au serveur, la tablette l'applique a son
/// echange suivant. Pas de « Reessayer » : la file renvoie deja l'ecriture a
/// chaque echange.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/fenetre_motif.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/tablettes_queries.dart';
import '../../data/repositories/repository_providers.dart';

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

class _CarteTablette extends ConsumerWidget {
  const _CarteTablette({required this.tablette});

  final TabletteSuivie tablette;

  Future<void> _renommer(BuildContext context, WidgetRef ref) async {
    final nom = await demanderMotif(
      context,
      titre: 'Renommer la tablette',
      icone: PhosphorIconsLight.pencilSimple,
      libelleMotif: 'Nom',
      indice: 'Ex. : Réception 1, Bar',
      valeurInitiale: tablette.nom,
      libelleConfirmer: 'Renommer',
      libelleRenoncer: 'Annuler',
      autofocus: true,
    );
    if (nom == null || nom.trim().isEmpty || !context.mounted) return;
    final refus = await ref.read(blocagesRepositoryProvider).renommer(tablette.id, nom);
    if (context.mounted) _dire(context, refus);
  }

  Future<void> _revoquer(BuildContext context, WidgetRef ref) async {
    final motif = await demanderMotif(
      context,
      titre: 'Révoquer ${tablette.nom} ?',
      icone: PhosphorIconsLight.xCircle,
      contenu: Text(
        '${tablette.estCelleCi ? 'C’est la tablette sur laquelle vous êtes. ' : ''}'
        'À son prochain contact avec le serveur, elle efface toutes ses '
        'données : clients, ardoises, codes des agents. Ce qu’elle n’a pas '
        'encore remonté est perdu. Ses sessions s’arrêtent tout de suite. '
        'Pour une tablette perdue ou volée.',
      ),
      libelleMotif: 'Motif (obligatoire)',
      libelleConfirmer: 'Révoquer',
      libelleRenoncer: 'Garder',
      danger: true,
      obligatoire: true,
    );
    if (motif == null || !context.mounted) return;
    final refus = await ref.read(blocagesRepositoryProvider).revoquer(tablette.id, motif);
    if (context.mounted) _dire(context, refus);
  }

  void _dire(BuildContext context, String? refus) {
    if (refus == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(refus)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                t.revoquee
                    ? 'Révoquée'
                    : t.bloquee
                    ? 'Bloquée'
                    : 'Rien de bloqué',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: t.revoquee || t.bloquee ? p.error : p.success,
                ),
              ),
              if (t.connue && !t.revoquee)
                PopupMenuButton<String>(
                  tooltip: 'Gérer la tablette',
                  icon: const Icon(PhosphorIconsLight.dotsThree),
                  onSelected: (choix) => choix == 'renommer'
                      ? _renommer(context, ref)
                      : _revoquer(context, ref),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'renommer', child: Text('Renommer')),
                    PopupMenuItem(
                      value: 'revoquer',
                      child: Text('Révoquer la tablette'),
                    ),
                  ],
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
          if (t.revoqueeLe case final le?) ...[
            const SizedBox(height: 8),
            Text(
              'Révoquée le ${_moment(le)}'
              '${t.revoqueePar == null ? '' : ' par ${t.revoqueePar}'}'
              '${t.motifRevocation == null ? '' : ' : « ${t.motifRevocation} »'}'
              '. Elle efface ses données à son prochain contact avec le '
              'serveur.',
              style: TextStyle(fontSize: 14, color: p.error),
            ),
          ],
          for (final b in ouverts) ...[
            const SizedBox(height: 12),
            _LigneBlocage(blocage: b, tablette: t.nom),
          ],
          if (leves.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Eyebrow('Levés cette semaine'),
            for (final b in leves) ...[
              const SizedBox(height: 6),
              _LigneBlocage(blocage: b, tablette: t.nom),
            ],
          ],
        ],
      ),
    );
  }
}

class _LigneBlocage extends ConsumerStatefulWidget {
  const _LigneBlocage({required this.blocage, required this.tablette});

  final BlocageVu blocage;
  final String tablette;

  @override
  ConsumerState<_LigneBlocage> createState() => _LigneBlocageState();
}

class _LigneBlocageState extends ConsumerState<_LigneBlocage> {
  bool _enCours = false;

  Future<void> _abandonner(String titre) async {
    final motif = await demanderMotif(
      context,
      titre: 'Abandonner cette saisie ?',
      icone: PhosphorIconsLight.trash,
      contenu: Text(
        '« $titre » quitte la file de ${widget.tablette} à son prochain '
        'échange, et ce qui attend derrière repart. La saisie est perdue : '
        'un encaissement ou une consommation disparaît de l’ardoise, une '
        'modification revient à la version du serveur.',
      ),
      libelleMotif: 'Motif (obligatoire)',
      libelleConfirmer: 'Abandonner',
      libelleRenoncer: 'Garder',
      danger: true,
      obligatoire: true,
    );
    if (motif == null || !mounted) return;
    setState(() => _enCours = true);
    final refus = await ref
        .read(blocagesRepositoryProvider)
        .abandonner(widget.blocage.id, motif);
    if (!mounted) return;
    setState(() => _enCours = false);
    if (refus != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(refus)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final b = widget.blocage;
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
            switch ((b.resolution, b.decision)) {
              ('SENT', _) => 'Passée',
              (_, 'ABANDON') => 'Abandonnée sur décision${_par(b)}',
              _ => 'Retirée de la file',
            },
            if (b.leveLe case final l?) 'le ${_moment(l)}',
            if (b.decision != null && b.motifDecision != null)
              '« ${b.motifDecision} »',
          ];
    final decision = b.ouvert && b.decision == 'ABANDON'
        ? 'Abandon demandé${_par(b)}'
              '${b.decideLe == null ? '' : ' le ${_moment(b.decideLe!)}'}'
              '${b.motifDecision == null ? '' : ' : « ${b.motifDecision} »'}. '
              'La tablette l’appliquera à son prochain échange.'
        : null;
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
          if (decision != null) ...[
            const SizedBox(height: 6),
            Text(
              decision,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
          ] else if (b.ouvert && b.abandonnable) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: _enCours ? null : () => _abandonner(titre),
                icon: const Icon(PhosphorIconsLight.trash, size: 18),
                label: const Text('Abandonner cette saisie'),
                style: OutlinedButton.styleFrom(foregroundColor: p.error),
              ),
            ),
          ] else if (b.ouvert && b.noteAbandon != null) ...[
            const SizedBox(height: 6),
            Text(
              b.noteAbandon!,
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: p.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _par(BlocageVu b) => b.decidePar == null ? '' : ' par ${b.decidePar}';

extension on String {
  String ifEmpty(String autre) => isEmpty ? autre : this;
}
