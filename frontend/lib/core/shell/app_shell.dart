/// La coque de l'application : un panneau de navigation bleu royal.
///
/// La navigation reste visible sur chaque ecran, dans le bleu de la charte,
/// collee au bord gauche : c'est le repere fixe de l'application, la page
/// blanche a cote est le plan de travail.
///
/// - **PC et tablette paysage** (>= 1100) : un panneau, les entrees rangees
///   comme on lit un hotel -- le pilotage, puis les sejours, les services et
///   l'argent ; l'administration a part, en bas, pres du compte ;
/// - **tablette portrait** (>= 600) : un rail d'icones, meme bleu en plus fin ;
/// - **telephone** : une barre d'onglets en bas, « Plus » pour le reste.
///
/// L'entree courante est marquee par une seule pastille qui glisse d'une
/// ligne a l'autre : on voit d'ou l'on vient et ou l'on arrive, au lieu
/// d'un surlignage qui saute.
///
/// Les entrees sont filtrees par les droits de l'agent (3.4) ; la vraie
/// barriere reste dans le routeur. Rien n'a disparu du menu d'origine : les
/// deux doublons (« Chambres » et « Plan des chambres », « Housekeeping » et
/// « A nettoyer ») menaient au meme ecran et n'en font plus qu'un, avec leur
/// compteur.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/ui/icons.dart';

import '../../data/local/queries/dashboard_queries.dart';
import '../../features/auth/session.dart';
import '../../features/dashboard/dashboard_screen.dart' show dashboardProvider;
import '../../features/dashboard/dashboard_sidebar.dart'
    show Avatar, MenuCompte, montantCompact;
import '../../features/reservations/reservations_screen.dart'
    show ReservationFilter, reservationFilterProvider;
import '../brand/atrium_logo.dart';
import '../theme_mode.dart';
import '../tokens.dart';
import '../ui/atrium_ui.dart';
import '../widgets/module_scaffold.dart' show PendingWritesBadge;

/// Les familles du menu, dans l'ordre ou un hotel se lit : d'abord la vue
/// d'ensemble, puis le client (de la reservation au depart), puis ce qui
/// fait tourner la maison, puis l'argent. Les reglages vivent a part.
enum Groupe { pilotage, sejours, services, finances, reglages }

extension on Groupe {
  /// `null` : le groupe n'a pas de titre (le pilotage ouvre le menu, les
  /// reglages sont poses en bas, a part).
  String? get libelle => switch (this) {
    Groupe.pilotage => null,
    Groupe.sejours => 'Séjours',
    Groupe.services => 'Services',
    Groupe.finances => 'Finances',
    Groupe.reglages => null,
  };
}

class Destination {
  const Destination(
    this.label,
    this.icon,
    this.iconActive,
    this.route,
    this.permission,
    this.groupe, {
    this.filtre,
    this.raccourci = false,
    this.indicateur,
  });

  /// Le nom sous l'icone du rail, ou la place manque.
  String get court => switch (label) {
    'Caisse du jour' => 'Caisse',
    'Réservations' => 'Résas',
    'Maintenance' => 'Entretien',
    'Administration' => 'Admin',
    _ => label,
  };

  final String label;
  final IconData icon;
  final IconData iconActive;

  /// `null` : module annonce mais pas encore livre.
  final String? route;

  /// `null` : ouverte a tous.
  final String? permission;
  final Groupe groupe;

  /// Pour « Arrivees » et « Departs » : le filtre pose sur les reservations.
  final ReservationFilter? filtre;

  /// Une vue du module Reservations, rangee sous son entree principale.
  final bool raccourci;

  /// Un chiffre du jour en bout de ligne.
  final String? Function(DashboardSummary)? indicateur;
}

final destinations = <Destination>[
  const Destination(
    "Aujourd'hui",
    PhosphorIconsLight.sun,
    PhosphorIconsFill.sun,
    '/',
    null,
    Groupe.pilotage,
  ),
  const Destination(
    'Statistiques',
    PhosphorIconsLight.squaresFour,
    PhosphorIconsFill.squaresFour,
    '/statistiques',
    null,
    Groupe.pilotage,
  ),
  const Destination(
    'Réservations',
    PhosphorIconsLight.calendarDots,
    PhosphorIconsFill.calendarDots,
    '/reservations',
    'reservation.read',
    Groupe.sejours,
  ),
  // Ce qui reste a faire, pas le total : le chiffre descend a mesure que la
  // reception avance, et disparait quand la journee est bouclee.
  Destination(
    'Arrivées',
    PhosphorIconsLight.signIn,
    PhosphorIconsFill.signIn,
    '/reservations',
    'reservation.read',
    Groupe.sejours,
    filtre: ReservationFilter.arrivalsToday,
    raccourci: true,
    indicateur: (r) =>
        r.arriveesRestantes == 0 ? null : '${r.arriveesRestantes}',
  ),
  Destination(
    'Départs',
    PhosphorIconsLight.signOut,
    PhosphorIconsFill.signOut,
    '/reservations',
    'reservation.read',
    Groupe.sejours,
    filtre: ReservationFilter.departuresToday,
    raccourci: true,
    indicateur: (r) => r.departsRestants == 0 ? null : '${r.departsRestants}',
  ),
  Destination(
    'Chambres',
    PhosphorIconsLight.bed,
    PhosphorIconsFill.bed,
    '/chambres',
    'reservation.read',
    Groupe.sejours,
    indicateur: (r) => r.chambresTotal == 0
        ? null
        : '${r.chambresOccupees}/${r.chambresTotal}',
  ),
  const Destination(
    'Clients',
    PhosphorIconsLight.users,
    PhosphorIconsFill.users,
    '/clients',
    'guests.read',
    Groupe.sejours,
  ),
  Destination(
    'Ménage',
    PhosphorIconsLight.broom,
    PhosphorIconsFill.broom,
    '/menage',
    'housekeeping.read',
    Groupe.services,
    indicateur: (r) =>
        r.chambresANettoyer == 0 ? null : '${r.chambresANettoyer}',
  ),
  const Destination(
    'Maintenance',
    PhosphorIconsLight.wrench,
    PhosphorIconsFill.wrench,
    '/maintenance',
    'maintenance.read',
    Groupe.services,
  ),
  const Destination(
    'Points de vente',
    PhosphorIconsLight.shoppingBagOpen,
    PhosphorIconsFill.shoppingBagOpen,
    '/commandes',
    'order.read',
    Groupe.services,
  ),
  const Destination(
    'Factures',
    PhosphorIconsLight.receipt,
    PhosphorIconsFill.receipt,
    '/factures',
    'folio.read',
    Groupe.finances,
  ),
  Destination(
    'Caisse du jour',
    PhosphorIconsLight.coins,
    PhosphorIconsFill.coins,
    '/caisse',
    'folio.read',
    Groupe.finances,
    indicateur: (r) => montantCompact(r.caDuJour),
  ),
  const Destination(
    'Administration',
    PhosphorIconsLight.lockSimple,
    PhosphorIconsFill.lockSimple,
    '/administration',
    'users.write',
    Groupe.reglages,
  ),
];

/// Les entrees permises a cet agent, dans l'ordre du menu.
List<Destination> destinationsPour(SessionState session) {
  final accueil = session.acces.homeRoute;
  final ecranUnique = accueil != null && accueil != '/';
  return [
    for (final d in destinations)
      if ((d.permission == null || session.acces.peut(d.permission!)) &&
          // Un metier a ecran unique (la femme de chambre) ne passe jamais
          // par l'accueil : lui montrer « Aujourd'hui » serait un detour.
          !(ecranUnique && (d.route == '/' || d.route == '/statistiques')))
        d,
  ];
}

int _indexActif(
  List<Destination> liste,
  String chemin,
  ReservationFilter filtre,
) {
  if (chemin == '/reservations') {
    final vue = liste.indexWhere(
      (d) => d.route == chemin && d.filtre == filtre,
    );
    if (vue >= 0) return vue;
  }
  var meilleur = -1;
  var longueur = -1;
  for (var i = 0; i < liste.length; i++) {
    final d = liste[i];
    final r = d.route;
    if (r == null || d.raccourci) continue;
    final correspond = r == '/'
        ? chemin == '/'
        : (chemin == r || chemin.startsWith('$r/'));
    if (correspond && r.length > longueur) {
      meilleur = i;
      longueur = r.length;
    }
  }
  return meilleur;
}

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final liste = destinationsPour(session);
    final actif = _indexActif(
      liste,
      location,
      ref.watch(reservationFilterProvider),
    );
    final largeur = MediaQuery.sizeOf(context).width;
    final resume = ref.watch(dashboardProvider).value;

    void aller(int i) {
      final d = liste[i];
      if (d.route == null) return;
      if (d.filtre != null) {
        ref.read(reservationFilterProvider.notifier).select(d.filtre!);
      } else if (d.route == '/reservations') {
        ref
            .read(reservationFilterProvider.notifier)
            .select(ReservationFilter.all);
      }
      context.go(d.route!);
    }

    final page = AmbientBackground(child: child);

    if (largeur >= 1100) {
      return Material(
        color: AtriumColors.background,
        child: Row(
          children: [
            _Ile(
              largeur: 256,
              child: _Barre(
                liste: liste,
                actif: actif,
                onSelect: aller,
                session: session,
                resume: resume,
              ),
            ),
            Expanded(child: page),
          ],
        ),
      );
    }
    if (largeur >= 600) {
      return Material(
        color: AtriumColors.background,
        child: Row(
          children: [
            _Ile(
              largeur: 92,
              child: _Rail(
                liste: liste,
                actif: actif,
                onSelect: aller,
                session: session,
              ),
            ),
            Expanded(child: page),
          ],
        ),
      );
    }
    return _CadreTelephone(
      liste: liste,
      actif: actif,
      onSelect: aller,
      session: session,
      child: page,
    );
  }
}

/// Le panneau : un aplat bleu, pleine hauteur, colle au bord. Le nom vient
/// d'une version flottante a coins ronds, retiree.
class _Ile extends StatelessWidget {
  const _Ile({required this.largeur, required this.child});

  final double largeur;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: largeur,
      color: _Nav.fond,
      child: SafeArea(
        right: false,
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}

// --- Barre etendue -----------------------------------------------------------

/// Les mesures de la barre. Fixes, parce que la pastille active se place par
/// calcul : une ligne qui changerait de hauteur la ferait glisser a cote.
abstract final class _Mesures {
  static const ligne = 38.0;
  static const pas = ligne + 2;
  static const titre = 26.0;
  static const premierTitre = 22.0;
}

class _Barre extends StatefulWidget {
  const _Barre({
    required this.liste,
    required this.actif,
    required this.onSelect,
    required this.session,
    required this.resume,
  });

  final List<Destination> liste;
  final int actif;
  final ValueChanged<int> onSelect;
  final SessionState session;
  final DashboardSummary? resume;

  @override
  State<_Barre> createState() => _BarreState();
}

class _BarreState extends State<_Barre> {
  late bool _reservationsOuvertes;

  bool get _surReservations =>
      widget.actif >= 0 && widget.liste[widget.actif].route == '/reservations';

  @override
  void initState() {
    super.initState();
    _reservationsOuvertes = _surReservations;
  }

  @override
  void didUpdateWidget(covariant _Barre oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actif != widget.actif && _surReservations) {
      _reservationsOuvertes = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final liste = widget.liste;
    final actif = widget.actif;
    final resume = widget.resume;
    final lignes = <Widget>[];
    final reglages = <int>[];
    // La hauteur de chaque ligne au-dessus de l'entree courante : c'est la
    // que la pastille doit se poser.
    double? hautActif;
    var hauteurActif = _Mesures.ligne;
    var retraitActif = 0.0;
    var y = 0.0;
    Groupe? groupe;

    for (var i = 0; i < liste.length; i++) {
      final d = liste[i];
      final sousEntree = d.route == '/reservations' && d.filtre != null;
      if (sousEntree && !_reservationsOuvertes) continue;
      if (d.groupe == Groupe.reglages) {
        reglages.add(i);
        continue;
      }
      if (d.groupe != groupe) {
        groupe = d.groupe;
        final titre = groupe.libelle;
        if (titre != null) {
          final hauteur = y == 0 ? _Mesures.premierTitre : _Mesures.titre;
          lignes.add(_TitreGroupe(titre: titre, hauteur: hauteur));
          y += hauteur;
        } else if (y > 0) {
          lignes.add(const SizedBox(height: _Mesures.titre / 2));
          y += _Mesures.titre / 2;
        }
      }
      final reservations = d.route == '/reservations' && d.filtre == null;
      final hauteur = reservations || sousEntree ? 48.0 : _Mesures.ligne;
      final selectionne =
          i == actif ||
          (reservations && _surReservations && !_reservationsOuvertes);
      if (selectionne) {
        hautActif = y;
        hauteurActif = hauteur;
        retraitActif = sousEntree ? 16 : 0;
      }
      final ligne = _LigneNav(
        destination: d,
        actif: selectionne,
        hauteur: hauteur,
        indicateur: resume == null ? null : d.indicateur?.call(resume),
        onTap: () {
          if (reservations) setState(() => _reservationsOuvertes = true);
          widget.onSelect(i);
        },
      );
      lignes.add(
        Padding(
          padding: EdgeInsets.only(
            left: sousEntree ? 16 : 0,
            bottom: _Mesures.pas - _Mesures.ligne,
          ),
          child: reservations
              ? Row(
                  children: [
                    Expanded(child: ligne),
                    Semantics(
                      expanded: _reservationsOuvertes,
                      child: IconButton(
                        tooltip: _reservationsOuvertes
                            ? 'Replier les réservations'
                            : 'Déplier les réservations',
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                        onPressed: () => setState(
                          () => _reservationsOuvertes = !_reservationsOuvertes,
                        ),
                        icon: AnimatedRotation(
                          turns: _reservationsOuvertes ? 0.25 : 0,
                          duration: AtriumMotion.of(context, AtriumMotion.base),
                          child: Icon(
                            PhosphorIconsLight.caretRight,
                            size: 18,
                            color: selectionne ? _Nav.iconePastille : _Nav.doux,
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : ligne,
        ),
      );
      y += hauteur + _Mesures.pas - _Mesures.ligne;
    }

    final duree = AtriumMotion.of(context, const Duration(milliseconds: 520));

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AtriumMark(size: 58, onNight: true),
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            // Un fondu au bas de la liste, seulement quand elle deborde : une
            // entree coupee net se lit comme un bug, une entree qui s'efface
            // se lit comme une liste qui continue. Quand tout tient, aucun
            // fondu : il estompait la derniere entree pour rien.
            child: LayoutBuilder(
              builder: (context, zone) {
                final menu = SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Stack(
                    children: [
                      // Une seule pastille pour tout le menu : elle glisse vers
                      // l'entree choisie au lieu de s'eteindre ici et de
                      // s'allumer la-bas.
                      AnimatedPositioned(
                        duration: duree,
                        curve: atriumSpring,
                        top: hautActif ?? 0,
                        left: retraitActif,
                        right: 0,
                        height: hauteurActif,
                        child: AnimatedOpacity(
                          duration: AtriumMotion.of(context, AtriumMotion.base),
                          opacity: hautActif == null ? 0 : 1,
                          child: const _Pastille(),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: lignes,
                      ),
                    ],
                  ),
                );
                if (y + 12 <= zone.maxHeight) return menu;
                return ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (r) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white, Colors.white, Colors.transparent],
                    stops: [0, 0.94, 1],
                  ).createShader(r),
                  child: menu,
                );
              },
            ),
          ),
          if (reglages.isNotEmpty) ...[
            const SizedBox(height: 4),
            for (final i in reglages)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: AnimatedOpacity(
                        duration: duree,
                        curve: atriumSpring,
                        opacity: i == actif ? 1 : 0,
                        child: const _Pastille(),
                      ),
                    ),
                    _LigneNav(
                      destination: liste[i],
                      actif: i == actif,
                      onTap: () => widget.onSelect(i),
                    ),
                  ],
                ),
              ),
          ] else
            const SizedBox(height: 8),
          _Compte(session: widget.session, etendu: true),
        ],
      ),
    );
  }
}

class _TitreGroupe extends StatelessWidget {
  const _TitreGroupe({required this.titre, required this.hauteur});

  final String titre;
  final double hauteur;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: hauteur,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 0, 7),
          child: Semantics(
            header: true,
            child: Text(
              titre,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _Nav.doux.withValues(alpha: 0.8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La pastille de l'entree courante : un aplat blanc sur le bleu, la ou se
/// pose l'oeil.
class _Pastille extends StatelessWidget {
  const _Pastille();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _Nav.pastille,
      ),
    );
  }
}

class _LigneNav extends StatefulWidget {
  const _LigneNav({
    required this.destination,
    required this.actif,
    required this.onTap,
    this.indicateur,
    this.hauteur = _Mesures.ligne,
  });

  final Destination destination;
  final bool actif;
  final VoidCallback onTap;
  final String? indicateur;
  final double hauteur;

  @override
  State<_LigneNav> createState() => _LigneNavState();
}

class _LigneNavState extends State<_LigneNav> {
  bool _survol = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.destination;
    final actif = widget.actif;
    final bientot = d.route == null;
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 360));
    final encre = actif
        ? _Nav.surPastille
        : _Nav.encre.withValues(alpha: bientot ? 0.45 : 0.82);

    return Semantics(
      button: true,
      selected: actif,
      child: InkWell(
        onTap: bientot ? null : widget.onTap,
        onHover: (v) => setState(() => _survol = v),
        borderRadius: BorderRadius.circular(10),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: _Nav.voile(0.10),
        child: AnimatedContainer(
          duration: duree,
          curve: atriumSpring,
          height: widget.hauteur,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            // L'aplat de l'entree courante est la pastille, posee dessous ;
            // la ligne n'apporte que le survol.
            color: _survol && !actif && !bientot
                ? _Nav.voile(0.07)
                : Colors.transparent,
          ),
          child: Row(
            children: [
              AnimatedSwitcher(
                duration: duree,
                child: Icon(
                  actif ? d.iconActive : d.icon,
                  key: ValueKey(actif),
                  size: 20,
                  color: actif ? _Nav.iconePastille : encre,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: duree,
                  curve: atriumSpring,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 14.5,
                    fontWeight: actif ? FontWeight.w600 : FontWeight.w500,
                    color: encre,
                  ),
                  child: Text(
                    d.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (bientot)
                Text(
                  'Bientôt',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: _Nav.doux.withValues(alpha: 0.5),
                  ),
                )
              else if (widget.indicateur != null)
                _Compteur(texte: widget.indicateur!, surPastille: actif),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le chiffre du jour en bout de ligne, en chiffres a chasse fixe : il change
/// dans la journee, il ne doit pas faire danser la ligne.
class _Compteur extends StatelessWidget {
  const _Compteur({required this.texte, required this.surPastille});

  final String texte;
  final bool surPastille;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AtriumMotion.of(context, AtriumMotion.base),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: surPastille
            ? _Nav.surPastille.withValues(alpha: 0.10)
            : _Nav.voile(0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        texte,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: surPastille ? _Nav.surPastille : _Nav.encre,
          fontFeatures: tabularFigures,
        ),
      ),
    );
  }
}

// --- Rail --------------------------------------------------------------------

class _Rail extends StatelessWidget {
  const _Rail({
    required this.liste,
    required this.actif,
    required this.onSelect,
    required this.session,
  });

  final List<Destination> liste;
  final int actif;
  final ValueChanged<int> onSelect;
  final SessionState session;

  @override
  Widget build(BuildContext context) {
    final entrees = <Widget>[];
    Groupe? groupe;
    for (var i = 0; i < liste.length; i++) {
      final d = liste[i];
      if (d.route == null || d.raccourci) continue;
      // Un trait court entre deux familles : le rail n'a pas la place des
      // titres, mais garde le meme rangement que la barre.
      if (groupe != null && d.groupe != groupe) {
        entrees.add(
          Center(
            child: Container(
              width: 22,
              height: 1,
              margin: const EdgeInsets.symmetric(vertical: 8),
              color: _Nav.voile(0.12),
            ),
          ),
        );
      }
      groupe = d.groupe;
      entrees.add(
        _EntreeRail(
          destination: d,
          actif:
              i == actif ||
              (d.route == '/reservations' &&
                  actif >= 0 &&
                  liste[actif].filtre != null),
          onTap: () => d.route == '/reservations'
              ? _choisirVueReservations(context, liste, actif, onSelect)
              : onSelect(i),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          const AtriumMark(size: 40, onNight: true),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: entrees),
          ),
          _Compte(session: session, etendu: false),
        ],
      ),
    );
  }
}

class _EntreeRail extends StatelessWidget {
  const _EntreeRail({
    required this.destination,
    required this.actif,
    required this.onTap,
  });

  final Destination destination;
  final bool actif;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 420));
    return Tooltip(
      message: destination.label,
      preferBelow: false,
      child: Semantics(
        button: true,
        selected: actif,
        label: destination.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: duree,
                  curve: atriumSpring,
                  width: 52,
                  height: 34,
                  decoration: BoxDecoration(
                    color: actif ? _Nav.pastille : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    actif ? destination.iconActive : destination.icon,
                    size: 21,
                    color: actif ? _Nav.iconePastille : _Nav.doux,
                  ),
                ),
                const SizedBox(height: 3),
                // Le nom sous l'icone : sans lui, un nouvel agent ne sait pas
                // ce que cache chaque pictogramme.
                Text(
                  destination.court,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 10.5,
                    fontWeight: actif ? FontWeight.w700 : FontWeight.w500,
                    color: actif ? _Nav.encre : _Nav.doux,
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

/// Dans le rail et sur telephone, les vues restent regroupees dans un menu
/// lisible, avec les memes droits et filtres que le panneau etendu.
void _choisirVueReservations(
  BuildContext context,
  List<Destination> liste,
  int actif,
  ValueChanged<int> onSelect,
) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.8,
    ),
    builder: (feuille) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Semantics(
                header: true,
                child: Text('Réservations', style: atriumDisplay(28)),
              ),
            ),
            for (var i = 0; i < liste.length; i++)
              if (liste[i].route == '/reservations')
                ListTile(
                  leading: Icon(
                    i == actif ? liste[i].iconActive : liste[i].icon,
                  ),
                  title: Text(
                    liste[i].filtre == null
                        ? 'Toutes les réservations'
                        : liste[i].label,
                  ),
                  selected: i == actif,
                  selectedTileColor: AtriumPalette.current.accentSoft,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  onTap: () {
                    Navigator.pop(feuille);
                    onSelect(i);
                  },
                ),
          ],
        ),
      ),
    ),
  );
}

/// Telephone : la page plein ecran, la navigation dans une pilule flottante.
class _CadreTelephone extends StatelessWidget {
  const _CadreTelephone({
    required this.liste,
    required this.actif,
    required this.onSelect,
    required this.session,
    required this.child,
  });

  final List<Destination> liste;
  final int actif;
  final ValueChanged<int> onSelect;
  final SessionState session;
  final Widget child;

  static const _visibles = 4;

  @override
  Widget build(BuildContext context) {
    final navigables = [
      for (var i = 0; i < liste.length; i++)
        if (liste[i].route != null && !liste[i].raccourci) i,
    ];
    if (navigables.length <= 1) return child;

    final onglets = navigables.take(_visibles).toList();
    final reste = navigables.skip(_visibles).toList();
    final principal = actif >= 0 && liste[actif].filtre != null
        ? liste.indexWhere(
            (d) => d.route == '/reservations' && d.filtre == null,
          )
        : actif;
    final actifDansPlus = reste.contains(principal);

    return Scaffold(
      body: child,
      extendBody: true,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: AtriumColors.white,
          border: Border(top: BorderSide(color: AtriumColors.border)),
        ),
        child: SafeArea(
          child: SizedBox(
            height: (MediaQuery.textScalerOf(context).scale(11) * 1.5 + 40)
                .clamp(64.0, double.infinity),
            child: Row(
              children: [
                for (final i in onglets)
                  Expanded(
                    child: _OngletTelephone(
                      label: liste[i].label,
                      icon: i == principal
                          ? liste[i].iconActive
                          : liste[i].icon,
                      actif: i == principal,
                      onTap: () => liste[i].route == '/reservations'
                          ? _choisirVueReservations(
                              context,
                              liste,
                              actif,
                              onSelect,
                            )
                          : onSelect(i),
                    ),
                  ),
                if (reste.isNotEmpty)
                  Expanded(
                    child: _OngletTelephone(
                      label: 'Plus',
                      icon: PhosphorIconsLight.dotsThree,
                      actif: actifDansPlus,
                      onTap: () => _ouvrirPlus(context, reste),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _ouvrirPlus(BuildContext context, List<int> reste) {
    showModalBottomSheet<void>(
      context: context,
      builder: (feuille) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final i in reste)
                ListTile(
                  leading: Icon(
                    i == actif ? liste[i].iconActive : liste[i].icon,
                    color: i == actif
                        ? AtriumColors.mintStrong
                        : AtriumColors.textSecondary,
                  ),
                  title: Text(liste[i].label),
                  selected: i == actif,
                  onTap: () {
                    Navigator.pop(feuille);
                    onSelect(i);
                  },
                ),
              const Divider(height: 24),
              Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Apparence',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AtriumColors.textPrimary,
                      ),
                    ),
                  ),
                  BoutonTheme(couleur: AtriumColors.textPrimary),
                ],
              ),
              ListTile(
                leading: Avatar(session: session, taille: 36),
                title: Text(session.nomAffiche),
                subtitle: Text(
                  session.acces.roles.isEmpty
                      ? 'Agent'
                      : session.acces.roles.first,
                ),
                trailing: TextButton.icon(
                  onPressed: () {
                    Navigator.pop(feuille);
                    ProviderScope.containerOf(
                      context,
                    ).read(sessionProvider.notifier).deconnecter();
                  },
                  icon: const Icon(PhosphorIconsLight.signOut),
                  label: const Text('Sortir'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OngletTelephone extends StatelessWidget {
  const _OngletTelephone({
    required this.label,
    required this.icon,
    required this.actif,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool actif;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 420));
    return Semantics(
      button: true,
      selected: actif,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: duree,
              curve: atriumSpring,
              width: 52,
              height: 30,
              decoration: BoxDecoration(
                color: actif
                    ? AtriumPalette.current.accentSoft
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 21,
                color: actif
                    ? AtriumColors.mintStrong
                    : AtriumColors.textSecondary,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 11,
                fontWeight: actif ? FontWeight.w700 : FontWeight.w500,
                color: actif
                    ? AtriumColors.textPrimary
                    : AtriumColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Compte extends StatelessWidget {
  const _Compte({required this.session, required this.etendu});

  final SessionState session;
  final bool etendu;

  @override
  Widget build(BuildContext context) {
    final role = session.acces.roles.isEmpty
        ? 'Agent'
        : session.acces.roles.first;
    final synchro = Theme(
      // Le badge prend ses couleurs dans le theme : celles de la nuit ici.
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(context).colorScheme.copyWith(
          onSurfaceVariant: _Nav.doux,
          tertiary: _Nav.encre,
          error: const Color(0xFFFFB4AE),
        ),
      ),
      child: PendingWritesBadge(compact: !etendu),
    );

    if (!etendu) {
      return Column(
        children: [
          const BoutonTheme(),
          synchro,
          const SizedBox(height: 6),
          MenuCompte(
            session: session,
            child: Avatar(session: session, taille: 40),
          ),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 10, 0, 0),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _Nav.voile(0.14))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: MenuCompte(
                  session: session,
                  child: Row(
                    children: [
                      Avatar(session: session, taille: 36),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              session.nomAffiche,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: atriumFontFamily,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: _Nav.encre,
                              ),
                            ),
                            Text(
                              role,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: atriumFontFamily,
                                fontSize: 12,
                                color: _Nav.doux,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const BoutonTheme(),
            ],
          ),
          // L'etat de la synchro sur sa propre ligne, toute la largeur : a
          // cote du nom, il le tronquait des la premiere ecriture en attente.
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: _Nav.voile(0.10))),
              ),
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Align(alignment: Alignment.centerLeft, child: synchro),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Clair ou sombre, a la demande : l'icone montre ce vers quoi on passe.
class BoutonTheme extends ConsumerWidget {
  const BoutonTheme({super.key, this.couleur});

  final Color? couleur;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sombre = AtriumPalette.current.isDark;
    return IconButton(
      tooltip: sombre ? 'Passer en mode clair' : 'Passer en mode sombre',
      onPressed: () => ref
          .read(themeModeProvider.notifier)
          .basculer(sombre ? Brightness.dark : Brightness.light),
      icon: AnimatedSwitcher(
        duration: AtriumMotion.of(context, const Duration(milliseconds: 360)),
        transitionBuilder: (enfant, a) => RotationTransition(
          turns: Tween(begin: 0.75, end: 1.0).animate(a),
          child: FadeTransition(opacity: a, child: enfant),
        ),
        child: Icon(
          sombre ? PhosphorIconsLight.sun : PhosphorIconsLight.moon,
          key: ValueKey(sombre),
          size: 22,
          color: couleur ?? _Nav.doux,
        ),
      ),
    );
  }
}

/// Les couleurs de la navigation : le panneau est bleu royal le jour, bleu
/// d'encre la nuit ; le texte y est blanc, l'entree courante est un aplat
/// blanc ou s'ecrit le bleu.
abstract final class _Nav {
  static bool get sombre => AtriumPalette.current.isDark;
  static Color get fond =>
      sombre ? const Color(0xFF0E1636) : AtriumPalette.current.primary;
  static Color get encre => Colors.white;
  static Color get doux =>
      sombre ? const Color(0xFFA9B6DA) : const Color(0xFFC3CFEF);
  static Color voile(double a) => Colors.white.withValues(alpha: a);

  static Color get pastille => sombre ? const Color(0xFF2A4BB0) : Colors.white;
  static Color get surPastille =>
      sombre ? Colors.white : AtriumPalette.current.primary;
  static Color get iconePastille => surPastille;
}
