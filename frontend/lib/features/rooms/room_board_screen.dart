/// Plan des chambres (cahier des charges, paragraphe 5.2).
///
/// Les chambres groupees par etage, une pastille de couleur chacune. La
/// couleur n'est **jamais** stockee : elle se calcule a partir des trois axes
/// independants de la chambre (occupation, proprete, hors service), via
/// `RoomBoardEntry.displayStatus`. Stocker un etat unique ferait que la
/// reception et le housekeeping s'ecraseraient mutuellement.
///
/// Aucun plan geometrique n'est necessaire : le paragraphe 5.2 est une liste
/// par etage. Le vrai plan interactif est une autre exigence (F1.7), et les
/// colonnes qui le porteraient (`rooms.map_x`, `map_y`) sont nullables.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formats.dart';
import '../../core/theme.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/rooms_queries.dart';
import 'room_detail_panel.dart';

final roomBoardProvider = StreamProvider<List<RoomBoardEntry>>(
  (ref) => ref.watch(databaseProvider).watchRoomBoard(),
);

/// Libelle et couleur de chaque pastille, en un seul endroit.
({String label, Color couleur}) apparence(RoomDisplayStatus etat) =>
    switch (etat) {
      RoomDisplayStatus.AVAILABLE => (
          label: 'Disponible',
          couleur: CouleursEtat.disponible
        ),
      RoomDisplayStatus.OCCUPIED => (
          label: 'Occupee',
          couleur: CouleursEtat.occupee
        ),
      RoomDisplayStatus.RESERVED => (
          label: 'Reservee',
          couleur: CouleursEtat.reservee
        ),
      RoomDisplayStatus.CLEANING => (
          label: 'Nettoyage',
          couleur: CouleursEtat.nettoyage
        ),
      RoomDisplayStatus.MAINTENANCE => (
          label: 'Maintenance',
          couleur: CouleursEtat.maintenance
        ),
    };

class RoomBoardScreen extends ConsumerWidget {
  const RoomBoardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chambres = ref.watch(roomBoardProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          iconSize: 28,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Plan des chambres'),
      ),
      body: chambres.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Lecture impossible : $e')),
        data: (liste) => _Plan(chambres: liste),
      ),
    );
  }
}

class _Plan extends StatelessWidget {
  const _Plan({required this.chambres});

  final List<RoomBoardEntry> chambres;

  @override
  Widget build(BuildContext context) {
    if (chambres.isEmpty) {
      return const Center(
        child: Text(
          'Aucune chambre parametree.',
          style: TextStyle(fontSize: 18),
        ),
      );
    }

    // `watchRoomBoard()` trie deja par etage puis par numero : il suffit de
    // regrouper en conservant l'ordre d'arrivee.
    final parEtage = <String, List<RoomBoardEntry>>{};
    for (final c in chambres) {
      parEtage.putIfAbsent(c.floorLabel ?? 'Sans etage', () => []).add(c);
    }

    return Column(
      children: [
        const _Legende(),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              for (final entree in parEtage.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 12, top: 4),
                  child: Text(
                    entree.key,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                _GrilleChambres(chambres: entree.value),
                const SizedBox(height: 28),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _GrilleChambres extends StatelessWidget {
  const _GrilleChambres({required this.chambres});

  final List<RoomBoardEntry> chambres;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, contraintes) {
        final colonnes = (contraintes.maxWidth / 200).floor().clamp(2, 8);
        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: colonnes,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.7,
          children: [
            for (final c in chambres) _CarteChambre(chambre: c),
          ],
        );
      },
    );
  }
}

class _CarteChambre extends StatelessWidget {
  const _CarteChambre({required this.chambre});

  final RoomBoardEntry chambre;

  @override
  Widget build(BuildContext context) {
    final vue = apparence(chambre.displayStatus);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => afficherFicheChambre(context, chambre),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: vue.couleur.withValues(alpha: 0.45)),
            // Bande de couleur a gauche : lisible en biais, quand la tablette
            // est posee sur le comptoir et qu'on la regarde de trois quarts.
            gradient: LinearGradient(
              colors: [
                vue.couleur.withValues(alpha: 0.14),
                Colors.white,
              ],
              stops: const [0, 0.22],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: vue.couleur,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    chambre.number,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                vue.label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: vue.couleur,
                ),
              ),
              Text(
                '${chambre.typeLabel} · ${montantFcfa(chambre.rate)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Legende extends StatelessWidget {
  const _Legende();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Wrap(
        spacing: 24,
        runSpacing: 10,
        children: [
          for (final etat in RoomDisplayStatus.values)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: apparence(etat).couleur,
                  ),
                ),
                const SizedBox(width: 8),
                Text(apparence(etat).label, style: const TextStyle(fontSize: 16)),
              ],
            ),
        ],
      ),
    );
  }
}
