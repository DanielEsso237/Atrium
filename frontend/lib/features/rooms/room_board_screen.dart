/// Plan des chambres (cahier des charges, paragraphe 5.2).
///
/// Les chambres groupees par etage. L'etat de chacune n'est **jamais**
/// stocke : il se calcule a partir des trois axes independants de la chambre
/// (occupation, proprete, hors service), via `RoomBoardEntry.displayStatus`.
/// Stocker un etat unique ferait que la reception et le housekeeping
/// s'ecraseraient mutuellement.
///
/// Aucun plan geometrique n'est necessaire : le paragraphe 5.2 est une liste
/// par etage. Le vrai plan interactif est une autre exigence (F1.7), et les
/// colonnes qui le porteraient (`rooms.map_x`, `map_y`) sont nullables.
///
/// Le plan se lit comme le tableau des cles derriere un comptoir : chaque
/// chambre est sa carte-cle, et toutes sont de la meme carte blanche, comme
/// les cles d'un meme hotel. L'etat ne teint jamais la carte, il vit dans un
/// badge colore, le voyant de la serrure. Cinq fonds de couleur se
/// disputeraient l'ecran ; cinq badges sur un meme blanc se lisent d'un coup
/// d'oeil, meme de loin.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/atrium_bandeau.dart';
import '../../core/widgets/atrium_puces.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../../data/remote/outbox_sender.dart';
import '../auth/session.dart';
import '../sync/sync_status.dart';
import 'room_cleaning_dialog.dart';
import 'room_detail_panel.dart';

final roomBoardProvider = StreamProvider<List<RoomBoardEntry>>(
  (ref) => ref.watch(databaseProvider).watchRoomBoard(),
);

/// Qui dort dans chaque chambre, ou qui y est attendu aujourd'hui.
final occupantsPlanProvider = StreamProvider<Map<String, OccupantPlan>>(
  (ref) => ref.watch(databaseProvider).watchOccupantsPlan(),
);

/// Construit une fois : `ThemeData` n'est pas gratuit.
final _theme = atriumBrandTheme();

/// L'apparence d'un etat de chambre, en un seul endroit : les badges, les
/// filtres, la barre des etages et la fiche doivent etre d'accord, sinon
/// l'ecran ment.
class ApparenceEtat {
  const ApparenceEtat({
    required this.label,
    required this.pluriel,
    required this.icone,
    required this.couleur,
    required this.fond,
    required this.encre,
    required this.voyant,
    required this.lueur,
  });

  final String label;

  /// Pour les filtres : « Occupées ».
  final String pluriel;
  final IconData icone;

  /// Le voyant sur fond clair, les barres.
  final Color couleur;

  /// Le fond du badge sur fond clair.
  final Color fond;

  /// Le texte pose sur ce fond.
  final Color encre;

  /// Sur le violet des cartes-cles : le voyant, plus vif pour briller sur le
  /// fond sombre...
  final Color voyant;

  /// ... et le libelle, pale.
  final Color lueur;
}

ApparenceEtat apparence(RoomDisplayStatus etat) => switch (etat) {
  RoomDisplayStatus.AVAILABLE => ApparenceEtat(
    label: 'Disponible',
    pluriel: 'Disponibles',
    icone: Icons.check_circle_outline_rounded,
    couleur: AtriumRoomColors.available,
    fond: AtriumRoomColors.availableTint,
    encre: AtriumRoomColors.availableInk,
    voyant: AtriumRoomColors.availableLed,
    lueur: AtriumRoomColors.availableOnDark,
  ),
  RoomDisplayStatus.OCCUPIED => const ApparenceEtat(
    label: 'Occupée',
    pluriel: 'Occupées',
    icone: Icons.hotel_rounded,
    couleur: AtriumRoomColors.occupied,
    fond: AtriumRoomColors.occupiedTint,
    encre: AtriumRoomColors.occupiedInk,
    voyant: AtriumRoomColors.occupiedLed,
    lueur: AtriumRoomColors.occupiedOnDark,
  ),
  RoomDisplayStatus.RESERVED => const ApparenceEtat(
    label: 'Réservée',
    pluriel: 'Réservées',
    icone: Icons.event_available_rounded,
    couleur: AtriumRoomColors.reserved,
    fond: AtriumRoomColors.reservedTint,
    encre: AtriumRoomColors.reservedInk,
    voyant: AtriumRoomColors.reservedLed,
    lueur: AtriumRoomColors.reservedOnDark,
  ),
  RoomDisplayStatus.CLEANING => const ApparenceEtat(
    label: 'Nettoyage',
    pluriel: 'Nettoyage',
    icone: Icons.cleaning_services_rounded,
    couleur: AtriumRoomColors.cleaning,
    fond: AtriumRoomColors.cleaningTint,
    encre: AtriumRoomColors.cleaningInk,
    voyant: AtriumRoomColors.cleaningLed,
    lueur: AtriumRoomColors.cleaningOnDark,
  ),
  RoomDisplayStatus.MAINTENANCE => const ApparenceEtat(
    label: 'Hors service',
    pluriel: 'Hors service',
    icone: Icons.build_rounded,
    couleur: AtriumRoomColors.outOfOrder,
    fond: AtriumRoomColors.outOfOrderTint,
    encre: AtriumRoomColors.outOfOrderInk,
    voyant: AtriumRoomColors.outOfOrderLed,
    lueur: AtriumRoomColors.outOfOrderOnDark,
  ),
};

/// L'ordre de lecture des etats : ce qui se vend d'abord, ce qui bloque
/// ensuite.
const _ordreEtats = [
  RoomDisplayStatus.AVAILABLE,
  RoomDisplayStatus.OCCUPIED,
  RoomDisplayStatus.RESERVED,
  RoomDisplayStatus.CLEANING,
  RoomDisplayStatus.MAINTENANCE,
];

class RoomBoardScreen extends ConsumerStatefulWidget {
  const RoomBoardScreen({super.key});

  @override
  ConsumerState<RoomBoardScreen> createState() => _RoomBoardScreenState();
}

class _RoomBoardScreenState extends ConsumerState<RoomBoardScreen>
    with SingleTickerProviderStateMixin {
  /// L'etat retenu par les filtres, `null` pour toutes les chambres.
  RoomDisplayStatus? _filtre;
  final _recherche = TextEditingController();

  /// La distribution des cles : les cartes arrivent l'une apres l'autre a
  /// l'ouverture du plan, puis a chaque changement de filtre, pour montrer
  /// que la selection a change. C'est le seul mouvement que l'ecran fait de
  /// lui-meme.
  late final _distribution = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  );
  var _distribuee = false;

  @override
  void dispose() {
    _distribution.dispose();
    _recherche.dispose();
    super.dispose();
  }

  void _distribuer() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _distribution.value = 1;
    } else {
      _distribution.forward(from: 0);
    }
  }

  void _choisirFiltre(RoomDisplayStatus? etat) {
    setState(() => _filtre = etat == _filtre ? null : etat);
    _distribuer();
  }

  @override
  Widget build(BuildContext context) {
    final chambres = ref.watch(roomBoardProvider);
    final occupants = ref.watch(occupantsPlanProvider).value ?? const {};
    final liste = chambres.value ?? const <RoomBoardEntry>[];
    final largeur = MediaQuery.sizeOf(context).width;
    final marge = largeur >= 900 ? 32.0 : (largeur >= 560 ? 24.0 : 16.0);
    final telephone = largeur < 600;

    // Les cles se distribuent quand le plan arrive, pas avant : il n'y a
    // rien a distribuer pendant la lecture de la base.
    if (!_distribuee && liste.isNotEmpty) {
      _distribuee = true;
      if (MediaQuery.disableAnimationsOf(context)) {
        _distribution.value = 1;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _distribution.forward(from: 0);
        });
      }
    }

    return Theme(
      data: _theme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
        ),
        child: Scaffold(
          backgroundColor: AtriumDashColors.page,
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _Bandeau(chambres: liste)),
              SliverPersistentHeader(
                pinned: true,
                delegate: _EnteteFiltres(
                  // Un point de plus pour le filet du bas, present meme transparent.
                  hauteur: telephone ? 139 : 81,
                  marge: marge,
                  telephone: telephone,
                  chambres: liste,
                  filtre: _filtre,
                  recherche: _recherche,
                  onFiltre: _choisirFiltre,
                  onRecherche: () => setState(() {}),
                ),
              ),
              ...chambres.when(
                loading: () => [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AtriumColors.mintStrong,
                      ),
                    ),
                  ),
                ],
                error: (e, _) => [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _Vide(
                      icone: Icons.error_outline_rounded,
                      texte: 'Lecture du plan impossible : $e',
                    ),
                  ),
                ],
                data: (liste) => _etages(liste, occupants, largeur, marge),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 40 + MediaQuery.paddingOf(context).bottom,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _etages(
    List<RoomBoardEntry> liste,
    Map<String, OccupantPlan> occupants,
    double largeur,
    double marge,
  ) {
    if (liste.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _Vide(
            icone: Icons.meeting_room_outlined,
            texte: 'Aucune chambre paramétrée.',
          ),
        ),
      ];
    }

    final requete = _recherche.text.trim().toLowerCase();
    bool retenue(RoomBoardEntry c) {
      if (_filtre != null && c.displayStatus != _filtre) return false;
      if (requete.isEmpty) return true;
      // On cherche ce que la reception a sous les yeux ou au telephone : un
      // numero, un nom de client, une categorie, un etage.
      return [
        c.number,
        c.typeLabel,
        c.floorLabel ?? '',
        occupants[c.roomId]?.nom ?? '',
      ].join(' ').toLowerCase().contains(requete);
    }

    // `watchRoomBoard()` trie deja par etage puis par numero : il suffit de
    // regrouper en conservant l'ordre d'arrivee.
    final parEtage = <String, List<RoomBoardEntry>>{};
    for (final c in liste) {
      parEtage.putIfAbsent(c.floorLabel ?? 'Sans étage', () => []).add(c);
    }

    final espace = largeur < 600 ? 12.0 : 16.0;
    final sections = <Widget>[];
    // Le rang de chaque carte dans tout le plan, pas dans son etage : la
    // distribution descend l'ecran d'un seul mouvement.
    var rang = 0;
    for (final MapEntry(key: etage, value: chambres) in parEtage.entries) {
      final visibles = chambres.where(retenue).toList();
      if (visibles.isEmpty) continue;
      final premier = rang;
      rang += visibles.length;
      sections
        ..add(
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              marge,
              sections.isEmpty ? 14 : 34,
              marge,
              16,
            ),
            sliver: SliverToBoxAdapter(
              child: _EnteteEtage(libelle: etage, chambres: chambres),
            ),
          ),
        )
        ..add(
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: marge),
            // La largeur reellement offerte a la grille, et non celle de
            // l'ecran : la navigation en prend sa part, et les cartes
            // tombaient sous leur minimum.
            sliver: SliverLayoutBuilder(
              builder: (context, contraintes) => SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  // Autant de cles par rangee qu'il en tient a 220 points au
                  // moins : en dessous, le nom du client et le prix se
                  // tronquent, et ce sont eux qu'on vient lire.
                  crossAxisCount: math.max(
                    1,
                    ((contraintes.crossAxisExtent + espace) / (220 + espace))
                        .floor(),
                  ),
                  mainAxisExtent: 172,
                  mainAxisSpacing: espace,
                  crossAxisSpacing: espace,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _Distribuee(
                    distribution: _distribution,
                    rang: premier + i,
                    child: _CarteCle(
                      chambre: visibles[i],
                      occupant: occupants[visibles[i].roomId],
                    ),
                  ),
                  childCount: visibles.length,
                ),
              ),
            ),
          ),
        );
    }

    if (sections.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _Vide(
            icone: Icons.search_off_rounded,
            texte: 'Aucune chambre ne correspond à ces filtres.',
            action: TextButton(
              onPressed: () {
                _recherche.clear();
                _choisirFiltre(null);
              },
              child: const Text('Afficher toutes les chambres'),
            ),
          ),
        ),
      ];
    }
    return sections;
  }
}

// --- Bandeau -----------------------------------------------------------------

class _Bandeau extends ConsumerWidget {
  const _Bandeau({required this.chambres});

  final List<RoomBoardEntry> chambres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haut = MediaQuery.paddingOf(context).top;
    final etages = chambres.map((c) => c.floorLabel).toSet().length;
    final libres = chambres
        .where((c) => c.displayStatus == RoomDisplayStatus.AVAILABLE)
        .length;

    // Ce que la reception veut savoir en arrivant sur le plan : combien de
    // chambres elle peut vendre tout de suite.
    final sousTitre = chambres.isEmpty
        ? 'Les chambres de l’hôtel, étage par étage.'
        : '${chambres.length} chambres sur $etages '
              'étage${etages > 1 ? 's' : ''}, dont $libres '
              '${libres > 1 ? 'prêtes' : 'prête'} à accueillir.';

    return LayoutBuilder(
      builder: (context, c) {
        final telephone = c.maxWidth < 600;
        final uneLigne = c.maxWidth >= 900;

        final titre = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Plan des chambres',
                style: atriumDisplay(telephone ? 32 : 42),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              sousTitre,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AtriumColors.textSecondary,
                height: 1.4,
              ),
            ),
            if (ref
                .watch(sessionProvider)
                .acces
                .peut('housekeeping.manage')) ...[
              const SizedBox(height: 12),
              PillButton(
                label: 'Ménage d’une chambre',
                icon: PhosphorIconsLight.broom,
                onPressed: () => showRoomCleaningDialog(context),
              ),
            ],
          ],
        );

        final actions = Wrap(
          spacing: AtriumSpacing.sm,
          runSpacing: AtriumSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!telephone) const PuceEtatConnexion(),
            const PuceEcritures(),
            _BoutonSynchroniser(compact: telephone),
          ],
        );

        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: haut + 120),
          child: Stack(
            children: [
              const Positioned.fill(child: AtriumBandeauFond()),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  telephone ? 18 : 32,
                  haut + (telephone ? 16 : 28),
                  telephone ? 18 : 32,
                  20,
                ),
                child: uneLigne
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(child: titre),
                          const SizedBox(width: AtriumSpacing.md),
                          actions,
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: actions,
                          ),
                          const SizedBox(height: AtriumSpacing.sm),
                          titre,
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Echange avec le serveur, a la demande : on remonte, puis on rapatrie.
///
/// Un bouton et non un rafraichissement automatique : la reception doit
/// pouvoir decider quand elle echange, et surtout voir si ca a marche.
class _BoutonSynchroniser extends ConsumerWidget {
  const _BoutonSynchroniser({required this.compact});

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
        ? 'Serveur injoignable : le plan garde les données de la tablette.'
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

// --- Filtres -----------------------------------------------------------------

/// La barre des filtres, qui reste en haut quand on fait defiler les etages :
/// un receptionniste qui cherche une chambre libre au cinquieme ne doit pas
/// remonter pour changer de filtre.
class _EnteteFiltres extends SliverPersistentHeaderDelegate {
  _EnteteFiltres({
    required this.hauteur,
    required this.marge,
    required this.telephone,
    required this.chambres,
    required this.filtre,
    required this.recherche,
    required this.onFiltre,
    required this.onRecherche,
  });

  final double hauteur;
  final double marge;
  final bool telephone;
  final List<RoomBoardEntry> chambres;
  final RoomDisplayStatus? filtre;
  final TextEditingController recherche;
  final ValueChanged<RoomDisplayStatus?> onFiltre;
  final VoidCallback onRecherche;

  @override
  double get minExtent => hauteur;

  @override
  double get maxExtent => hauteur;

  @override
  Widget build(BuildContext context, double decalage, bool recouvre) {
    final compte = <RoomDisplayStatus, int>{for (final e in _ordreEtats) e: 0};
    for (final c in chambres) {
      compte[c.displayStatus] = compte[c.displayStatus]! + 1;
    }

    final capsule = _Capsule(
      segments: [
        _Segment(
          libelle: 'Toutes',
          nombre: chambres.length,
          apparence: null,
          choisi: filtre == null,
          onTap: () => onFiltre(null),
        ),
        for (final e in _ordreEtats)
          _Segment(
            libelle: apparence(e).pluriel,
            nombre: compte[e]!,
            apparence: apparence(e),
            choisi: filtre == e,
            onTap: () => onFiltre(e),
          ),
      ],
    );

    final champ = _ChampRecherche(controleur: recherche, onChange: onRecherche);

    return AnimatedContainer(
      duration: AtriumMotion.of(context, AtriumMotion.base),
      decoration: BoxDecoration(
        color: AtriumDashColors.page,
        // Un filet sous la barre, seulement quand elle passe par-dessus les
        // cartes : au repos, elle fait partie de la page.
        border: Border(
          bottom: BorderSide(
            color: recouvre ? AtriumDashColors.cardBorder : Colors.transparent,
          ),
        ),
        boxShadow: recouvre ? AtriumShadows.soft : null,
      ),
      padding: EdgeInsets.fromLTRB(marge, 12, marge, 12),
      child: telephone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 48, child: champ),
                const SizedBox(height: 10),
                SizedBox(height: 56, child: capsule),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(height: 56, child: capsule),
                  ),
                ),
                const SizedBox(width: AtriumSpacing.md),
                SizedBox(width: 300, height: 56, child: champ),
              ],
            ),
    );
  }

  @override
  bool shouldRebuild(_EnteteFiltres ancien) =>
      ancien.filtre != filtre ||
      ancien.chambres != chambres ||
      ancien.hauteur != hauteur ||
      ancien.marge != marge ||
      ancien.telephone != telephone;
}

/// Les filtres dans une seule capsule, comme un selecteur : un etat a la
/// fois, et le compte de chacun sous les yeux. La capsule epouse ses
/// segments et defile quand l'ecran est trop etroit.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.segments});

  final List<Widget> segments;

  @override
  Widget build(BuildContext context) {
    final rayon = BorderRadius.circular(AtriumRadii.md + 2);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AtriumColors.white,
        borderRadius: rayon,
        border: Border.all(color: AtriumDashColors.cardBorder),
        boxShadow: AtriumShadows.soft,
      ),
      child: ClipRRect(
        borderRadius: rayon,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(4),
          child: Row(children: segments),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.libelle,
    required this.nombre,
    required this.apparence,
    required this.choisi,
    required this.onTap,
  });

  final String libelle;
  final int nombre;

  /// `null` pour « Toutes ».
  final ApparenceEtat? apparence;
  final bool choisi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rayon = BorderRadius.circular(AtriumRadii.md - 2);
    final p = AtriumPalette.current;
    // Le segment retenu prend le bleu de la navigation : sur ce fond, les
    // voyants vifs des etats ressortent.
    final fondChoisi = p.selected;
    final encre = choisi ? p.onSelected : AtriumDashColors.title;

    return Semantics(
      button: true,
      selected: choisi,
      label: '$libelle : $nombre',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: rayon,
          child: AnimatedContainer(
            duration: AtriumMotion.of(context, AtriumMotion.base),
            curve: AtriumMotion.standard,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: choisi ? fondChoisi : Colors.transparent,
              borderRadius: rayon,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (apparence == null)
                  Icon(
                    Icons.grid_view_rounded,
                    size: 16,
                    color: choisi ? p.onSelected : AtriumDashColors.title,
                  )
                else
                  _Voyant(
                    couleur: choisi ? apparence!.voyant : apparence!.couleur,
                    allume: nombre > 0,
                    taille: 8,
                  ),
                const SizedBox(width: AtriumSpacing.xs),
                Text(
                  libelle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: encre,
                  ),
                ),
                const SizedBox(width: AtriumSpacing.xs),
                Text(
                  '$nombre',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: choisi
                        ? p.onSelected.withValues(alpha: 0.78)
                        : AtriumColors.textSecondary,
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

class _ChampRecherche extends StatelessWidget {
  const _ChampRecherche({required this.controleur, required this.onChange});

  final TextEditingController controleur;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final rayon = BorderRadius.circular(18);
    OutlineInputBorder bord(Color c, [double e = 1]) => OutlineInputBorder(
      borderRadius: rayon,
      borderSide: BorderSide(color: c, width: e),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: rayon,
        boxShadow: AtriumShadows.soft,
      ),
      // La croix d'effacement suit le texte, pas la barre : la barre ne se
      // reconstruit pas a chaque lettre.
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controleur,
        builder: (context, valeur, _) => TextField(
          controller: controleur,
          onChanged: (_) => onChange(),
          expands: true,
          maxLines: null,
          textAlignVertical: TextAlignVertical.center,
          textInputAction: TextInputAction.search,
          style: TextStyle(fontSize: 15, color: AtriumColors.ink),
          decoration: InputDecoration(
            hintText: 'Numéro, client ou catégorie',
            hintStyle: TextStyle(
              fontSize: 14.5,
              color: AtriumColors.textSecondary,
            ),
            filled: true,
            fillColor: AtriumColors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            prefixIcon: Icon(
              Icons.search_rounded,
              color: AtriumColors.textSecondary,
              size: 22,
            ),
            suffixIcon: valeur.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Effacer la recherche',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: AtriumColors.textSecondary,
                    onPressed: () {
                      controleur.clear();
                      onChange();
                    },
                  ),
            border: bord(AtriumDashColors.cardBorder),
            enabledBorder: bord(AtriumDashColors.cardBorder),
            focusedBorder: bord(AtriumColors.mintStrong, 1.5),
          ),
        ),
      ),
    );
  }
}

// --- Etages ------------------------------------------------------------------

class _EnteteEtage extends StatelessWidget {
  const _EnteteEtage({required this.libelle, required this.chambres});

  final String libelle;
  final List<RoomBoardEntry> chambres;

  @override
  Widget build(BuildContext context) {
    final libres = chambres
        .where((c) => c.displayStatus == RoomDisplayStatus.AVAILABLE)
        .length;

    return LayoutBuilder(
      builder: (context, c) {
        // En dessous de 700 points, le compte passe sous le nom de l'etage,
        // qui se tronquait sinon.
        final etroit = c.maxWidth < 700;
        final nom = Text(
          libelle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: etroit ? 18 : 20,
            fontWeight: FontWeight.w700,
            color: AtriumDashColors.title,
            height: 1.2,
          ),
        );
        final compte = Text(
          '${chambres.length} chambre${chambres.length > 1 ? 's' : ''}, '
          '$libres libre${libres > 1 ? 's' : ''}',
          style: TextStyle(fontSize: 13.5, color: AtriumColors.textSecondary),
        );

        if (etroit) {
          return Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [nom, const SizedBox(height: 2), compte],
                ),
              ),
              const SizedBox(width: AtriumSpacing.md),
              SizedBox(width: 96, child: _BarreEtage(chambres: chambres)),
            ],
          );
        }

        // Le filet conduit l'oeil du nom de l'etage a sa repartition.
        return Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: c.maxWidth * 0.35),
              child: nom,
            ),
            const SizedBox(width: AtriumSpacing.sm),
            compte,
            const SizedBox(width: AtriumSpacing.lg),
            Expanded(
              child: SizedBox(
                height: 1,
                child: ColoredBox(color: AtriumColors.border),
              ),
            ),
            const SizedBox(width: AtriumSpacing.lg),
            SizedBox(width: 168, child: _BarreEtage(chambres: chambres)),
          ],
        );
      },
    );
  }
}

/// La repartition des etats d'un etage, en une barre : on voit d'un coup
/// d'oeil l'etage plein et celui ou il reste de la place.
class _BarreEtage extends StatelessWidget {
  const _BarreEtage({required this.chambres});

  final List<RoomBoardEntry> chambres;

  @override
  Widget build(BuildContext context) {
    final compte = <RoomDisplayStatus, int>{};
    for (final c in chambres) {
      compte[c.displayStatus] = (compte[c.displayStatus] ?? 0) + 1;
    }
    final presents = [
      for (final e in _ordreEtats)
        if ((compte[e] ?? 0) > 0) e,
    ];
    final resume = [
      for (final e in presents)
        '${compte[e]} ${apparence(e).label.toLowerCase()}',
    ].join(', ');

    return Tooltip(
      message: resume,
      child: Semantics(
        label: 'Répartition de l’étage : $resume',
        child: ExcludeSemantics(
          child: SizedBox(
            height: 8,
            // Etiree en hauteur : sans contenu, un segment prendrait sinon
            // la hauteur minimale, zero.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < presents.length; i++) ...[
                  // Un espace de 2 points entre les segments, et non un
                  // contour : c'est lui qui les separe.
                  if (i > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: compte[presents[i]]!,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: apparence(presents[i]).couleur,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
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

// --- Badge d'etat ------------------------------------------------------------

/// Le voyant d'etat, comme la diode d'une serrure a carte : un point de
/// couleur, avec un halo quand il est « allume ».
class _Voyant extends StatelessWidget {
  const _Voyant({required this.couleur, this.allume = true, this.taille = 9});

  final Color couleur;
  final bool allume;
  final double taille;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: allume ? couleur : couleur.withValues(alpha: 0.35),
        boxShadow: allume
            ? [
                BoxShadow(
                  color: couleur.withValues(alpha: 0.6),
                  blurRadius: 7,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );
  }
}

/// Le badge d'etat : le voyant et le libelle, dans la couleur de l'etat.
///
/// Deux poses : sur le violet des cartes-cles et de la fiche (`surFonce`), le
/// badge s'allume, voyant vif et libelle pale sur un fond teinte ; sur fond
/// clair, il prend le fond pale de l'etat et son encre.
///
/// Un seul texte, voyant compris : il se tronque de lui-meme dans une carte
/// etroite, et prend sa largeur naturelle dans une rangee qui ne le borne pas.
class PastilleEtat extends StatelessWidget {
  const PastilleEtat({
    super.key,
    required this.apparence,
    this.surFonce = false,
  });

  final ApparenceEtat apparence;
  final bool surFonce;

  @override
  Widget build(BuildContext context) {
    final a = apparence;
    final voyant = surFonce ? a.voyant : a.couleur;

    return Container(
      padding: const EdgeInsets.fromLTRB(9, 5, 11, 5),
      decoration: BoxDecoration(
        color: surFonce ? a.voyant.withValues(alpha: 0.2) : a.fond,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: voyant.withValues(alpha: surFonce ? 0.45 : 0.3),
        ),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _Voyant(couleur: voyant, taille: 7),
              ),
            ),
            TextSpan(text: a.label),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          height: 1.2,
          color: surFonce ? a.lueur : a.encre,
        ),
      ),
    );
  }
}

// --- Cartes-cles -------------------------------------------------------------

/// Une carte qui arrive dans la distribution des cles : elle glisse d'un
/// rien, pivote et se pose, comme une cle tendue sur le comptoir.
class _Distribuee extends StatelessWidget {
  const _Distribuee({
    required this.distribution,
    required this.rang,
    required this.child,
  });

  final Animation<double> distribution;
  final int rang;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Les treize premieres cartes partent en decale, le temps de remplir un
    // ecran ; les suivantes arrivent avec la derniere, sans faire attendre.
    final debut = math.min(rang, 12) * 0.04;
    final courbe = Interval(debut, debut + 0.5, curve: Curves.easeOutCubic);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: distribution,
        child: child,
        builder: (context, carte) {
          final t = courbe.transform(distribution.value);
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 18),
              child: Transform.rotate(
                angle: (1 - t) * -0.035,
                child: Transform.scale(scale: 0.94 + 0.06 * t, child: carte),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CarteCle extends StatefulWidget {
  const _CarteCle({required this.chambre, required this.occupant});

  final RoomBoardEntry chambre;
  final OccupantPlan? occupant;

  @override
  State<_CarteCle> createState() => _CarteCleState();
}

class _CarteCleState extends State<_CarteCle> {
  /// La carte s'enfonce sous le doigt : on sait qu'on l'a prise avant que la
  /// fiche s'ouvre.
  var _enfoncee = false;

  @override
  Widget build(BuildContext context) {
    final chambre = widget.chambre;
    final vue = apparence(chambre.displayStatus);
    final situation = _situation(chambre, widget.occupant);
    final rayon = BorderRadius.circular(AtriumRadii.md);

    return Semantics(
      button: true,
      label:
          'Chambre ${chambre.number}, ${chambre.typeLabel}, ${vue.label}. '
          '${situation.titre}'
          '${situation.detail == null ? '' : ', ${situation.detail}'}',
      excludeSemantics: true,
      child: AnimatedScale(
        scale: _enfoncee ? 0.97 : 1,
        duration: AtriumMotion.of(context, AtriumMotion.fast),
        curve: AtriumMotion.standard,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: rayon,
            color: AtriumColors.white,
            boxShadow: AtriumShadows.soft,
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: rayon,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => afficherFicheChambre(context, chambre),
              onHighlightChanged: (v) => setState(() => _enfoncee = v),
              splashColor: AtriumColors.ink.withValues(alpha: 0.05),
              highlightColor: AtriumColors.ink.withValues(alpha: 0.03),
              focusColor: AtriumColors.mintStrong.withValues(alpha: 0.12),
              child: AnimatedContainer(
                duration: AtriumMotion.of(context, AtriumMotion.fast),
                decoration: BoxDecoration(
                  borderRadius: rayon,
                  // Le filet fonce sous le doigt : la carte prise se detache
                  // des autres avant que la fiche ne s'ouvre.
                  border: Border.all(
                    color: _enfoncee
                        ? AtriumColors.textSecondary.withValues(alpha: 0.45)
                        : AtriumDashColors.cardBorder,
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            // La nuit, la carte devient sombre : le badge
                            // prend alors sa pose allumee.
                            child: PastilleEtat(
                              apparence: vue,
                              surFonce: AtriumPalette.current.isDark,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          chambre.number,
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w700,
                            color: AtriumColors.ink,
                            height: 1,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                        const SizedBox(width: AtriumSpacing.xs),
                        Flexible(
                          child: Text(
                            chambre.typeLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: AtriumColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    // L'identite de la chambre au-dessus du filet, ce qui s'y
                    // passe en dessous.
                    SizedBox(
                      height: 1,
                      width: double.infinity,
                      child: ColoredBox(color: AtriumDashColors.grid),
                    ),
                    const SizedBox(height: 11),
                    _LigneSituation(situation: situation),
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

/// Ce que la carte dit de la chambre, sous le filet.
class _Situation {
  const _Situation({
    required this.titre,
    this.detail,
    this.icone,
    this.initiales,
    this.progression,
    this.enRetard = false,
  });

  final String titre;
  final String? detail;
  final IconData? icone;

  /// Les initiales du client present, a la place de l'icone.
  final String? initiales;

  /// Part du sejour ecoulee, de 0 a 1, pour un client present.
  final double? progression;

  /// Client encore en chambre apres sa date de depart : le detail passe en
  /// rouge. Seule exception a l'encre de la page -- c'est une anomalie, pas
  /// un etat.
  final bool enRetard;
}

_Situation _situation(RoomBoardEntry c, OccupantPlan? occupant) {
  final aujourdhui = businessDayFor(DateTime.now());

  if (occupant != null && occupant.present) {
    final nuits = occupant.depart.difference(occupant.arrivee).inDays;
    final ecoulees = aujourdhui.difference(occupant.arrivee).inDays;
    return _Situation(
      titre: occupant.nom,
      detail: _depart(occupant.depart, aujourdhui),
      // Un depart oublie se voit sur le plan, pas seulement dans la cloche.
      enRetard: occupant.depart.isBefore(aujourdhui),
      initiales: _initiales(occupant.nom),
      progression: nuits <= 0 ? 1 : ((ecoulees + 1) / nuits).clamp(0.0, 1.0),
    );
  }
  if (c.isOutOfOrder) {
    return const _Situation(
      titre: 'Indisponible',
      detail: 'Retirée de la vente',
      icone: Icons.build_rounded,
    );
  }
  if (c.housekeeping == HousekeepingStatus.DIRTY) {
    return _Situation(
      titre: 'Ménage à faire',
      detail: occupant == null ? null : 'Attendue : ${occupant.nom}',
      icone: Icons.cleaning_services_rounded,
    );
  }
  if (c.housekeeping == HousekeepingStatus.IN_PROGRESS) {
    return const _Situation(
      titre: 'Ménage en cours',
      icone: Icons.cleaning_services_rounded,
    );
  }
  if (occupant != null) {
    return _Situation(
      titre: occupant.nom,
      detail: 'Arrive aujourd’hui',
      icone: Icons.event_available_rounded,
    );
  }
  return _Situation(
    titre: 'Prête à accueillir',
    detail: '${formatAmount(c.rate)} la nuit',
    icone: Icons.key_rounded,
  );
}

String _depart(DateTime depart, DateTime aujourdhui) {
  final jours = depart.difference(aujourdhui).inDays;
  if (jours < 0) return 'Départ dépassé (prévu le ${formatDayMonth(depart)})';
  if (jours == 0) return 'Départ aujourd’hui';
  if (jours == 1) return 'Départ demain';
  return 'Départ le ${formatShortDate(depart).substring(0, 5)}';
}

String _initiales(String nom) {
  final mots = nom.split(' ').where((m) => m.isNotEmpty).toList();
  return mots.take(2).map((m) => m.characters.first.toUpperCase()).join();
}

/// Le pied de la carte. Tout y est dans l'encre de la page, quel que soit
/// l'etat : seul le badge porte la couleur, sinon les cartes cesseraient
/// d'etre les memes.
class _LigneSituation extends StatelessWidget {
  const _LigneSituation({required this.situation});

  final _Situation situation;

  @override
  Widget build(BuildContext context) {
    final s = situation;
    return Row(
      children: [
        if (s.initiales != null)
          _Monogramme(initiales: s.initiales!, progression: s.progression ?? 0)
        else
          _Pictogramme(icone: s.icone ?? Icons.meeting_room_outlined),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.titre,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AtriumColors.ink,
                  height: 1.25,
                ),
              ),
              if (s.detail != null)
                Text(
                  s.detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: s.enRetard
                        ? AtriumColors.error
                        : AtriumColors.textSecondary,
                    fontWeight: s.enRetard ? FontWeight.w600 : null,
                    height: 1.3,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Les initiales du client present, cerclees de l'avancement de son sejour :
/// la reception voit sans calculer qui part bientot.
class _Monogramme extends StatelessWidget {
  const _Monogramme({required this.initiales, required this.progression});

  final String initiales;
  final double progression;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 38,
      child: CustomPaint(
        painter: _AnneauSejour(progression),
        child: Center(
          child: Container(
            width: 29,
            height: 29,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AtriumPalette.current.tileMango,
              shape: BoxShape.circle,
            ),
            child: Text(
              initiales,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AtriumPalette.current.tileMangoInk,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnneauSejour extends CustomPainter {
  const _AnneauSejour(this.progression);

  final double progression;

  @override
  void paint(Canvas canvas, Size taille) {
    final zone = (Offset.zero & taille).deflate(1.5);
    final trait = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      zone,
      0,
      2 * math.pi,
      false,
      trait..color = AtriumDashColors.grid,
    );
    if (progression > 0) {
      canvas.drawArc(
        zone,
        -math.pi / 2,
        2 * math.pi * progression,
        false,
        trait..color = AtriumColors.purple,
      );
    }
  }

  @override
  bool shouldRepaint(_AnneauSejour ancien) => ancien.progression != progression;
}

class _Pictogramme extends StatelessWidget {
  const _Pictogramme({required this.icone});

  final IconData icone;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: AtriumColors.surface,
        shape: BoxShape.circle,
        border: Border.all(color: AtriumDashColors.grid),
      ),
      child: Icon(icone, size: 18, color: AtriumColors.textSecondary),
    );
  }
}

class _Vide extends StatelessWidget {
  const _Vide({required this.icone, required this.texte, this.action});

  final IconData icone;
  final String texte;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Une cle vierge : la carte blanche du plan, sans numero.
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AtriumColors.white,
                borderRadius: BorderRadius.circular(AtriumRadii.md),
                border: Border.all(color: AtriumDashColors.cardBorder),
                boxShadow: AtriumShadows.soft,
              ),
              child: Icon(icone, size: 28, color: AtriumColors.mintStrong),
            ),
            const SizedBox(height: AtriumSpacing.md),
            Text(
              texte,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: AtriumColors.ink),
            ),
            if (action != null) ...[
              const SizedBox(height: AtriumSpacing.sm),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
