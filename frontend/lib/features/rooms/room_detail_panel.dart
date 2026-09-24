/// La fiche qui s'ouvre au clic sur une chambre (paragraphe 5.2).
///
/// Le cahier des charges impose son contenu : numero, type, prix, client
/// actuel, dates, consommations, etat, historique, et les trois boutons
/// Check-in / Check-out / Ajouter consommation.
///
/// Les trois boutons sont inertes pour l'instant : ce sont des ecritures, et
/// une ecriture locale qui ne remonterait jamais au serveur serait pire que
/// pas de bouton du tout. Ils s'activeront avec la couche de liaison.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/room_detail_queries.dart';
import '../../data/local/queries/rooms_queries.dart';
import 'room_board_screen.dart';

final ficheChambreProvider =
    StreamProvider.family<FicheChambre, String>((ref, roomId) {
  return ref.watch(databaseProvider).watchFicheChambre(roomId);
});

/// Ouvre la fiche en panneau lateral.
///
/// Un panneau plutot qu'une page : la reception garde le plan sous les yeux et
/// ferme d'un geste, ce qui compte quand on enchaine dix chambres.
void afficherFicheChambre(BuildContext context, RoomBoardEntry chambre) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.9,
      child: _Fiche(chambre: chambre),
    ),
  );
}

class _Fiche extends ConsumerWidget {
  const _Fiche({required this.chambre});

  final RoomBoardEntry chambre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fiche = ref.watch(ficheChambreProvider(chambre.roomId));
    final vue = apparence(chambre.displayStatus);
    final schema = Theme.of(context).colorScheme;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF4F6F8),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          _Entete(chambre: chambre, vue: vue),
          Expanded(
            child: fiche.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Lecture impossible : $e')),
              data: (f) => ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [
                  _Caracteristiques(chambre: chambre),
                  const SizedBox(height: 16),
                  if (f.sejour != null) ...[
                    _Sejour(sejour: f.sejour!),
                    const SizedBox(height: 16),
                    _Consommations(lignes: f.consommations),
                  ] else
                    _Bloc(
                      titre: 'Sejour en cours',
                      enfant: Text(
                        'Aucun client dans cette chambre.',
                        style: TextStyle(fontSize: 17, color: schema.outline),
                      ),
                    ),
                  const SizedBox(height: 16),
                  _Historique(sejours: f.historique),
                ],
              ),
            ),
          ),
          _Actions(occupee: fiche.value?.estOccupee ?? false),
        ],
      ),
    );
  }
}

class _Entete extends StatelessWidget {
  const _Entete({required this.chambre, required this.vue});

  final RoomBoardEntry chambre;
  final ({String label, Color couleur}) vue;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(bottom: BorderSide(color: vue.couleur, width: 3)),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: vue.couleur,
            ),
          ),
          const SizedBox(width: 14),
          Text(
            'Chambre ${chambre.number}',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 14),
          Chip(
            label: Text(vue.label),
            backgroundColor: vue.couleur.withValues(alpha: 0.12),
            side: BorderSide(color: vue.couleur.withValues(alpha: 0.4)),
            labelStyle: TextStyle(color: vue.couleur, fontSize: 15),
          ),
          const Spacer(),
          IconButton(
            iconSize: 30,
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _Caracteristiques extends StatelessWidget {
  const _Caracteristiques({required this.chambre});

  final RoomBoardEntry chambre;

  @override
  Widget build(BuildContext context) {
    return _Bloc(
      titre: 'La chambre',
      enfant: Column(
        children: [
          _Ligne(cle: 'Categorie', valeur: chambre.typeLabel),
          _Ligne(cle: 'Tarif de reference', valeur: formatAmount(chambre.rate)),
          _Ligne(cle: 'Etage', valeur: chambre.floorLabel ?? '—'),
          // Les trois axes, affiches separement et non fondus en un seul mot :
          // c'est ce qui permet a la reception et au housekeeping de lire la
          // meme fiche sans se contredire.
          _Ligne(cle: 'Occupation', valeur: chambre.occupancy.name),
          _Ligne(cle: 'Proprete', valeur: chambre.housekeeping.name),
          _Ligne(
            cle: 'Hors service',
            valeur: chambre.isOutOfOrder ? 'oui' : 'non',
          ),
        ],
      ),
    );
  }
}

class _Sejour extends StatelessWidget {
  const _Sejour({required this.sejour});

  final SejourEnCours sejour;

  @override
  Widget build(BuildContext context) {
    final arrivee = parseIsoDate(sejour.arrivee);
    final depart = parseIsoDate(sejour.depart);

    return _Bloc(
      titre: 'Sejour en cours',
      enfant: Column(
        children: [
          _Ligne(cle: 'Client', valeur: sejour.clientNom, gras: true),
          _Ligne(
            cle: 'Arrivee',
            valeur: arrivee == null ? sejour.arrivee : formatShortDate(arrivee),
          ),
          _Ligne(
            cle: 'Depart',
            valeur: depart == null ? sejour.depart : formatShortDate(depart),
          ),
          _Ligne(
            cle: 'Personnes',
            valeur: '${sejour.adultes} adulte(s), ${sejour.enfants} enfant(s)',
          ),
          _Ligne(cle: 'Tarif de la nuit', valeur: formatAmount(sejour.tarifNuit)),
          _Ligne(
            cle: 'Solde de l\'ardoise',
            valeur: formatAmount(sejour.soldeArdoise),
            gras: true,
          ),
        ],
      ),
    );
  }
}

class _Consommations extends StatelessWidget {
  const _Consommations({required this.lignes});

  final List<Consommation> lignes;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return _Bloc(
      titre: 'Consommations',
      enfant: lignes.isEmpty
          ? Text(
              'Aucune consommation portee a l\'ardoise.',
              style: TextStyle(fontSize: 17, color: schema.outline),
            )
          : Column(
              children: [
                for (final l in lignes)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.libelle,
                                  style: const TextStyle(fontSize: 17)),
                              Text(
                                '${l.categorie.name} · ${l.journee}',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: schema.outline,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          formatAmount(l.montant),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Historique extends StatelessWidget {
  const _Historique({required this.sejours});

  final List<SejourPasse> sejours;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return _Bloc(
      titre: 'Historique',
      enfant: sejours.isEmpty
          ? Text(
              'Aucun sejour termine dans cette chambre.',
              style: TextStyle(fontSize: 17, color: schema.outline),
            )
          : Column(
              children: [
                for (final s in sejours)
                  _Ligne(
                    cle: s.clientNom,
                    valeur: '${s.arrivee} → ${s.depart}',
                  ),
              ],
            ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.occupee});

  final bool occupee;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE0E0E0))),
      ),
      child: Row(
        children: [
          // TODO(api) : POST /reservations/{id}/rooms/{ligne}/check-in
          Expanded(
            child: FilledButton.icon(
              onPressed: null,
              icon: const Icon(Icons.login),
              label: const Text('Check-in'),
            ),
          ),
          const SizedBox(width: 12),
          // TODO(api) : POST .../check-out
          Expanded(
            child: OutlinedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.logout),
              label: const Text('Check-out'),
            ),
          ),
          const SizedBox(width: 12),
          // TODO(api) : POST /folios/{id}/items
          Expanded(
            child: OutlinedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('Consommation'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bloc extends StatelessWidget {
  const _Bloc({required this.titre, required this.enfant});

  final String titre;
  final Widget enfant;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              titre.toUpperCase(),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            enfant,
          ],
        ),
      ),
    );
  }
}

class _Ligne extends StatelessWidget {
  const _Ligne({required this.cle, required this.valeur, this.gras = false});

  final String cle;
  final String valeur;
  final bool gras;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 170,
            child: Text(
              cle,
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: Text(
              valeur,
              style: TextStyle(
                fontSize: 17,
                fontWeight: gras ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
