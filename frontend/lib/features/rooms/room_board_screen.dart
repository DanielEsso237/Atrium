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
import '../../core/tokens.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../../data/remote/outbox_sender.dart';
import '../sync/sync_status.dart';
import 'room_detail_panel.dart';

final roomBoardProvider = StreamProvider<List<RoomBoardEntry>>(
  (ref) => ref.watch(databaseProvider).watchRoomBoard(),
);

/// Libelle et couleur de chaque pastille, en un seul endroit.
({String label, Color couleur}) apparence(RoomDisplayStatus etat) =>
    switch (etat) {
      RoomDisplayStatus.AVAILABLE => (
        label: 'Disponible',
        couleur: CouleursEtat.disponible,
      ),
      RoomDisplayStatus.OCCUPIED => (
        label: 'Occupée',
        couleur: CouleursEtat.occupee,
      ),
      RoomDisplayStatus.RESERVED => (
        label: 'Réservée',
        couleur: CouleursEtat.reservee,
      ),
      RoomDisplayStatus.CLEANING => (
        label: 'Nettoyage',
        couleur: CouleursEtat.nettoyage,
      ),
      RoomDisplayStatus.MAINTENANCE => (
        label: 'Maintenance',
        couleur: CouleursEtat.maintenance,
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
        title: const Text('Chambres'),
        actions: [
          const PendingWritesBadge(),
          const SizedBox(width: 8),
          _BoutonRafraichir(),
          const SizedBox(width: 16),
        ],
      ),
      body: chambres.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Lecture impossible : $e')),
        data: (liste) => _Plan(chambres: liste),
      ),
    );
  }
}

class _Plan extends StatefulWidget {
  const _Plan({required this.chambres});

  final List<RoomBoardEntry> chambres;

  @override
  State<_Plan> createState() => _PlanState();
}

class _PlanState extends State<_Plan> {
  /// Etat filtre, ou tous. Toucher un compteur de la legende n'affiche que
  /// ces chambres : « ou puis-je mettre ce client ? » en un geste.
  RoomDisplayStatus? _filtre;

  @override
  Widget build(BuildContext context) {
    final chambres = widget.chambres;
    if (chambres.isEmpty) {
      return Center(
        child: Text(
          'Aucune chambre parametree.',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
    }

    final compte = <RoomDisplayStatus, int>{};
    for (final c in chambres) {
      compte.update(c.displayStatus, (n) => n + 1, ifAbsent: () => 1);
    }

    // `watchRoomBoard()` trie deja par etage puis par numero : il suffit de
    // regrouper en conservant l'ordre d'arrivee.
    final parEtage = <String, List<RoomBoardEntry>>{};
    for (final c in chambres) {
      if (_filtre != null && c.displayStatus != _filtre) continue;
      parEtage.putIfAbsent(c.floorLabel ?? 'Sans etage', () => []).add(c);
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Legende(
            compte: compte,
            total: chambres.length,
            filtre: _filtre,
            onFiltre: (etat) => setState(
              () => _filtre = _filtre == etat ? null : etat,
            ),
          ),
        ),
        if (parEtage.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                'Aucune chambre dans cet etat.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
        for (final entree in parEtage.entries) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            sliver: SliverToBoxAdapter(
              child: _TitreEtage(
                libelle: entree.key,
                chambres: entree.value,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 210,
                mainAxisExtent: 136,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _Apparition(
                  rang: i,
                  child: _CarteChambre(chambre: entree.value[i]),
                ),
                childCount: entree.value.length,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

/// Le nom de l'etage, et ce qu'il reste de libre : ce que la reception
/// cherche d'abord en ouvrant le plan.
class _TitreEtage extends StatelessWidget {
  const _TitreEtage({required this.libelle, required this.chambres});

  final String libelle;
  final List<RoomBoardEntry> chambres;

  @override
  Widget build(BuildContext context) {
    final libres = chambres
        .where((c) => c.displayStatus == RoomDisplayStatus.AVAILABLE)
        .length;
    final texte = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(child: Text(libelle, style: texte.titleLarge)),
        Text(
          libres == 0
              ? 'complet'
              : '$libres libre${libres > 1 ? 's' : ''} sur ${chambres.length}',
          style: texte.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Une apparition courte et decalee des tuiles, au premier affichage.
/// Nulle quand le systeme demande de reduire les animations.
class _Apparition extends StatelessWidget {
  const _Apparition({required this.rang, required this.child});

  final int rang;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final delai = (rang * 35).clamp(0, 350);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 380 + delai),
      curve: Interval(delai / (380 + delai), 1, curve: Curves.easeOutExpo),
      builder: (context, t, enfant) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - t)),
          child: enfant,
        ),
      ),
      child: child,
    );
  }
}

class _CarteChambre extends StatelessWidget {
  const _CarteChambre({required this.chambre});

  final RoomBoardEntry chambre;

  @override
  Widget build(BuildContext context) {
    final vue = apparence(chambre.displayStatus);
    final texte = Theme.of(context).textTheme;
    final sombre = Theme.of(context).brightness == Brightness.dark;
    final rayon = BorderRadius.circular(AtriumRadii.lg);

    // La couleur d'etat teinte toute la tuile : lisible de loin et en biais,
    // quand la tablette est posee a plat sur le comptoir.
    final fond = Color.alphaBlend(
      vue.couleur.withValues(alpha: sombre ? 0.16 : 0.10),
      AtriumColors.white,
    );

    return Material(
      color: fond,
      borderRadius: rayon,
      child: InkWell(
        borderRadius: rayon,
        onTap: () => afficherFicheChambre(context, chambre),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: rayon,
            border: Border.all(
              color: vue.couleur.withValues(alpha: sombre ? 0.45 : 0.35),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chambre.number,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: texte.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontFeatures: tabularFigures,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 6),
                _PastilleEtat(label: vue.label, couleur: vue.couleur),
                const Spacer(),
                Text(
                  chambre.typeLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: texte.titleSmall,
                ),
                Text(
                  formatAmount(chambre.rate),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: texte.bodySmall?.copyWith(
                    fontFeatures: tabularFigures,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// L'etat en toutes lettres : la couleur seule ne suffit pas a un lecteur
/// daltonien, ni en plein soleil.
class _PastilleEtat extends StatelessWidget {
  const _PastilleEtat({required this.label, required this.couleur});

  final String label;
  final Color couleur;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: couleur,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AtriumColors.purpleNight,
        ),
      ),
    );
  }
}

/// La legende est aussi un filtre : chaque etat avec son nombre de chambres.
class _Legende extends StatelessWidget {
  const _Legende({
    required this.compte,
    required this.total,
    required this.filtre,
    required this.onFiltre,
  });

  final Map<RoomDisplayStatus, int> compte;
  final int total;
  final RoomDisplayStatus? filtre;
  final ValueChanged<RoomDisplayStatus> onFiltre;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final etat in RoomDisplayStatus.values)
            _FiltreEtat(
              label: apparence(etat).label,
              couleur: apparence(etat).couleur,
              nombre: compte[etat] ?? 0,
              actif: filtre == etat,
              estompe: filtre != null && filtre != etat,
              onTap: () => onFiltre(etat),
            ),
        ],
      ),
    );
  }
}

class _FiltreEtat extends StatelessWidget {
  const _FiltreEtat({
    required this.label,
    required this.couleur,
    required this.nombre,
    required this.actif,
    required this.estompe,
    required this.onTap,
  });

  final String label;
  final Color couleur;
  final int nombre;
  final bool actif;
  final bool estompe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final duree = AtriumMotion.of(context, AtriumMotion.base);
    final rayon = BorderRadius.circular(99);
    return AnimatedOpacity(
      duration: duree,
      opacity: estompe ? 0.45 : 1,
      child: Material(
        color: actif
            ? couleur.withValues(alpha: 0.18)
            : AtriumColors.white,
        borderRadius: rayon,
        child: InkWell(
          borderRadius: rayon,
          onTap: onTap,
          child: AnimatedContainer(
            duration: duree,
            curve: AtriumMotion.standard,
            constraints: const BoxConstraints(minHeight: cibleTactile - 4),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: rayon,
              border: Border.all(
                color: actif ? couleur : AtriumColors.border,
                width: actif ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: couleur,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: 15,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$nombre',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AtriumColors.textSecondary,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Echange avec le serveur, a la demande : on remonte, puis on rapatrie.
///
/// Un bouton et non un rafraichissement automatique : la reception doit
/// pouvoir decider quand elle echange, et surtout voir si ca a marche.
class _BoutonRafraichir extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);

    if (sync.running) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    return IconButton(
      iconSize: 28,
      tooltip: 'Echanger avec le serveur',
      icon: const Icon(Icons.sync),
      onPressed: () async {
        await ref.read(syncProvider.notifier).refresh();
        if (!context.mounted) return;

        final etat = ref.read(syncProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_resume(etat)),
            // Une file bloquee ne se resout pas toute seule : elle reste
            // affichee le temps d'etre lue, en rouge, contrairement au reste.
            duration: etat.isBlocked
                ? const Duration(seconds: 10)
                : const Duration(seconds: 4),
            backgroundColor: etat.isBlocked
                ? Theme.of(context).colorScheme.error
                : null,
          ),
        );
      },
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
    return 'Une ecriture est refusee par le serveur et bloque les suivantes : '
        '${push.detail}';
  }
  if (push != null && push.arret == DrainStop.sessionInvalide) {
    return 'Session expiree — reconnectez-vous pour remonter les ecritures.';
  }

  final monte = push?.envoyees ?? 0;
  final remonte = monte == 0
      ? null
      : '$monte ecriture${monte > 1 ? 's' : ''} remontee${monte > 1 ? 's' : ''}';

  if (pull == null || pull.offline) {
    return remonte == null
        ? 'Serveur injoignable — le plan garde les donnees de la tablette.'
        : '$remonte, puis le serveur a cesse de repondre.';
  }
  if (!pull.succeeded) {
    return 'Echec : ${pull.error}';
  }

  // Les chambres et les donnees metier descendent ensemble ; on annonce le
  // total, parce que c'est « la tablette a-t-elle rattrape le serveur » que
  // la reception veut savoir, pas le detail par table.
  final metier = etat.pull?.total ?? 0;
  final descendu = metier == 0
      ? '${pull.rooms} chambres rapatriees'
      : '${pull.rooms + metier} lignes rapatriees';

  final ecartees = etat.pull?.skipped ?? 0;
  final reserve = ecartees == 0
      ? ''
      : ' — $ecartees ligne${ecartees > 1 ? 's' : ''} epargnee'
            '${ecartees > 1 ? 's' : ''}, non encore remontee'
            '${ecartees > 1 ? 's' : ''}';

  return remonte == null
      ? '$descendu$reserve.'
      : '$remonte, $descendu$reserve.';
}
