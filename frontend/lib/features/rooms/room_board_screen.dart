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

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../../data/remote/outbox_sender.dart';
import '../dashboard/dashboard_sidebar.dart' show montantCompact;
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
    final liste = chambres.value ?? const <RoomBoardEntry>[];
    final libres = liste
        .where((c) => c.displayStatus == RoomDisplayStatus.AVAILABLE)
        .length;

    return ModuleScaffold(
      title: 'Plan des chambres',
      subtitle: liste.isEmpty
          ? null
          : '${liste.length} chambres  ·  $libres libre${libres > 1 ? 's' : ''} '
                'en ce moment',
      action: const _BoutonRafraichir(),
      body: chambres.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: PhosphorIconsLight.warningCircle,
          title: 'Lecture impossible',
          message: '$e',
        ),
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
      return const EmptyState(
        icon: PhosphorIconsLight.bed,
        title: 'Aucune chambre paramétrée',
        message:
            'Les chambres descendent du serveur : lancez une synchronisation.',
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
      parEtage.putIfAbsent(c.floorLabel ?? 'Sans étage', () => []).add(c);
    }

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final etages = parEtage.entries.toList();

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(marge, 0, marge, 8),
          sliver: SliverToBoxAdapter(
            child: FilterPills<RoomDisplayStatus?>(
              selected: _filtre,
              onChanged: (etat) =>
                  setState(() => _filtre = (_filtre == etat) ? null : etat),
              options: [
                FilterOption(null, 'Toutes', count: chambres.length),
                for (final etat in RoomDisplayStatus.values)
                  FilterOption(
                    etat,
                    apparence(etat).label,
                    count: compte[etat] ?? 0,
                    color: apparence(etat).couleur,
                  ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(marge, 12, marge, 36),
          sliver: SliverList.builder(
            itemCount: etages.length,
            itemBuilder: (context, i) => FadeUp(
              index: i.clamp(0, 6),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _Etage(
                  libelle: etages[i].key,
                  chambres: etages[i].value,
                  filtre: _filtre,
                  etroit: etroit,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Un etage : son nom et ce qu'il reste de libre a gauche, comme la coupe
/// d'un immeuble, ses chambres a droite. Les chambres hors filtre restent a
/// leur place, estompees : l'etage garde sa forme, on ne perd pas le fil.
class _Etage extends StatelessWidget {
  const _Etage({
    required this.libelle,
    required this.chambres,
    required this.filtre,
    required this.etroit,
  });

  final String libelle;
  final List<RoomBoardEntry> chambres;
  final RoomDisplayStatus? filtre;
  final bool etroit;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final libres = chambres
        .where((c) => c.displayStatus == RoomDisplayStatus.AVAILABLE)
        .length;

    final tete = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          libelle,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            height: 1.15,
            color: p.text,
          ),
        ),
        const SizedBox(height: 10),
        _Jauge(chambres: chambres),
        const SizedBox(height: 8),
        Text(
          libres == 0
              ? 'Complet'
              : '$libres libre${libres > 1 ? 's' : ''} sur ${chambres.length}',
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: libres == 0 ? p.accent : p.textSecondary,
            fontFeatures: tabularFigures,
          ),
        ),
      ],
    );

    final tuiles = Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < chambres.length; i++)
          _Apparition(
            rang: i,
            child: _CarteChambre(
              chambre: chambres[i],
              estompee: filtre != null && chambres[i].displayStatus != filtre,
            ),
          ),
      ],
    );

    return Bezel(
      radius: 26,
      padding: const EdgeInsets.all(16),
      child: etroit
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [tete, const SizedBox(height: 14), tuiles],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: tete,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: tuiles),
              ],
            ),
    );
  }
}

/// La composition d'un etage en une barre : un segment par chambre, dans la
/// couleur de son etat.
class _Jauge extends StatelessWidget {
  const _Jauge({required this.chambres});

  final List<RoomBoardEntry> chambres;

  @override
  Widget build(BuildContext context) {
    final tries = [...chambres]
      ..sort((a, b) => a.displayStatus.index.compareTo(b.displayStatus.index));
    return SizedBox(
      width: 120,
      height: 6,
      child: Row(
        children: [
          for (var i = 0; i < tries.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  color: apparence(tries[i].displayStatus).couleur,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ],
      ),
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
    final delai = (rang * 40).clamp(0, 400);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 560 + delai),
      curve: Interval(delai / (560 + delai), 1, curve: atriumSpring),
      builder: (context, t, enfant) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.94 + 0.06 * t, child: enfant),
      ),
      child: child,
    );
  }
}

class _CarteChambre extends StatefulWidget {
  const _CarteChambre({required this.chambre, required this.estompee});

  final RoomBoardEntry chambre;
  final bool estompee;

  @override
  State<_CarteChambre> createState() => _CarteChambreState();
}

class _CarteChambreState extends State<_CarteChambre> {
  bool _survol = false;
  bool _presse = false;

  @override
  Widget build(BuildContext context) {
    final chambre = widget.chambre;
    final p = AtriumPalette.current;
    final vue = apparence(chambre.displayStatus);
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 420));

    // La couleur d'etat teinte toute la tuile : lisible de loin et en biais,
    // quand la tablette est posee a plat sur le comptoir.
    final fond = Color.alphaBlend(
      vue.couleur.withValues(alpha: p.isDark ? 0.13 : 0.09),
      p.paper,
    );

    // Le second axe, en petit : une chambre libre mais pas encore
    // inspectee, ou occupee et sale, se lit sans ouvrir la fiche.
    final (IconData icone, String detail) = switch (chambre.housekeeping) {
      _ when chambre.isOutOfOrder => (
        PhosphorIconsLight.wrench,
        'Hors service',
      ),
      HousekeepingStatus.DIRTY => (PhosphorIconsLight.broom, 'Sale'),
      HousekeepingStatus.IN_PROGRESS => (PhosphorIconsLight.broom, 'En cours'),
      HousekeepingStatus.INSPECTED => (
        PhosphorIconsLight.sealCheck,
        'Inspectée',
      ),
      HousekeepingStatus.CLEAN => (PhosphorIconsLight.sparkle, 'Propre'),
    };

    return AnimatedOpacity(
      duration: duree,
      curve: atriumSpring,
      opacity: widget.estompee ? 0.28 : 1,
      child: Semantics(
        button: true,
        label: 'Chambre ${chambre.number}, ${vue.label}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _survol = true),
          onExit: (_) => setState(() => _survol = false),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _presse = true),
            onTapCancel: () => setState(() => _presse = false),
            onTapUp: (_) => setState(() => _presse = false),
            onTap: () => afficherFicheChambre(context, chambre),
            child: AnimatedScale(
              duration: duree,
              curve: atriumSpring,
              scale: _presse ? 0.96 : (_survol ? 1.02 : 1),
              child: AnimatedContainer(
                duration: duree,
                curve: atriumSpring,
                width: 142,
                height: 116,
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                decoration: BoxDecoration(
                  color: fond,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: vue.couleur.withValues(
                      alpha: _survol ? 0.8 : (p.isDark ? 0.35 : 0.3),
                    ),
                    width: _survol ? 1.6 : 1,
                  ),
                  boxShadow: _survol
                      ? [
                          BoxShadow(
                            color: vue.couleur.withValues(alpha: 0.25),
                            blurRadius: 22,
                            spreadRadius: -8,
                            offset: const Offset(0, 10),
                          ),
                        ]
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: vue.couleur,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: vue.couleur.withValues(alpha: 0.6),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            vue.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: atriumFontFamily,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: p.textSecondary,
                            ),
                          ),
                        ),
                        Tooltip(
                          message: detail,
                          child: Icon(icone, size: 15, color: p.textSecondary),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      chambre.number,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                        height: 1,
                        color: p.text,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${chambre.typeLabel} · ${montantCompact(chambre.rate)} F',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: p.textSecondary,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ],
                ),
              ),
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
  const _BoutonRafraichir();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);

    return PillButton(
      label: sync.running ? 'Synchronisation…' : 'Synchroniser',
      icon: PhosphorIconsLight.arrowsClockwise,
      tone: PillTone.quiet,
      onPressed: sync.running
          ? null
          : () async {
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
