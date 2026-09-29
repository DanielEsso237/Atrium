/// La coque de l'application : une ile de navigation flottante.
///
/// La navigation reste visible sur chaque ecran, detachee des bords comme un
/// objet pose sur la page :
///
/// - **PC et tablette paysage** (>= 1100) : une ile verticale de nuit, avec
///   les entrees rangees par metier (reception, operations, gestion) ;
/// - **tablette portrait** (>= 600) : un rail d'icones, meme ile en plus fin ;
/// - **telephone** : une pilule flottante en bas, « Plus » pour le reste.
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

enum Groupe { reception, operations, gestion }

extension on Groupe {
  String get libelle => switch (this) {
    Groupe.reception => 'Réception',
    Groupe.operations => 'Opérations',
    Groupe.gestion => 'Gestion',
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
    'Plan des chambres' => 'Chambres',
    'Caisse du jour' => 'Caisse',
    'Statistiques' => 'Stats',
    'Réservations' => 'Résas',
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

  /// Un raccourci vers un ecran deja au menu : jamais surligne comme actif.
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
    Groupe.reception,
  ),
  const Destination(
    'Arrivées',
    PhosphorIconsLight.signIn,
    PhosphorIconsFill.signIn,
    '/reservations',
    'rooms.read',
    Groupe.reception,
    filtre: ReservationFilter.arrivalsToday,
    raccourci: true,
  ),
  const Destination(
    'Départs',
    PhosphorIconsLight.signOut,
    PhosphorIconsFill.signOut,
    '/reservations',
    'rooms.read',
    Groupe.reception,
    filtre: ReservationFilter.departuresToday,
    raccourci: true,
  ),
  const Destination(
    'Réservations',
    PhosphorIconsLight.calendarDots,
    PhosphorIconsFill.calendarDots,
    '/reservations',
    'rooms.read',
    Groupe.reception,
  ),
  const Destination(
    'Plan des chambres',
    PhosphorIconsLight.bed,
    PhosphorIconsFill.bed,
    '/chambres',
    'rooms.read',
    Groupe.reception,
  ),
  Destination(
    'Ménage',
    PhosphorIconsLight.broom,
    PhosphorIconsFill.broom,
    '/menage',
    'housekeeping.read',
    Groupe.operations,
    indicateur: (r) =>
        r.chambresANettoyer == 0 ? null : '${r.chambresANettoyer}',
  ),
  const Destination(
    'Maintenance',
    PhosphorIconsLight.wrench,
    PhosphorIconsFill.wrench,
    null,
    'maintenance.read',
    Groupe.operations,
  ),
  const Destination(
    'Restaurant',
    PhosphorIconsLight.forkKnife,
    PhosphorIconsFill.forkKnife,
    '/commandes',
    'order.read',
    Groupe.operations,
  ),
  const Destination(
    'Clients',
    PhosphorIconsLight.users,
    PhosphorIconsFill.users,
    '/clients',
    'guests.read',
    Groupe.gestion,
  ),
  const Destination(
    'Factures',
    PhosphorIconsLight.receipt,
    PhosphorIconsFill.receipt,
    '/factures',
    'folio.read',
    Groupe.gestion,
  ),
  Destination(
    'Caisse du jour',
    PhosphorIconsLight.coins,
    PhosphorIconsFill.coins,
    '/caisse',
    'folio.read',
    Groupe.gestion,
    indicateur: (r) => montantCompact(r.caDuJour),
  ),
  const Destination(
    'Statistiques',
    PhosphorIconsLight.chartLineUp,
    PhosphorIconsFill.chartLineUp,
    '/statistiques',
    null,
    Groupe.gestion,
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

int _indexActif(List<Destination> liste, String chemin) {
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
    final actif = _indexActif(liste, location);
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
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 0, 14),
              child: _Ile(
                largeur: 262,
                child: _Barre(
                  liste: liste,
                  actif: actif,
                  onSelect: aller,
                  session: session,
                  resume: resume,
                ),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
              child: _Ile(
                largeur: 92,
                child: _Rail(
                  liste: liste,
                  actif: actif,
                  onSelect: aller,
                  session: session,
                ),
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

/// L'ile : une plaque de nuit detachee des bords, filet clair, ombre teintee.
class _Ile extends StatelessWidget {
  const _Ile({required this.largeur, required this.child});

  final double largeur;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: largeur,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.alphaBlend(_Nav.teinteHaut, _Nav.fond), _Nav.fond],
        ),
        border: Border.all(color: _Nav.voile(0.07)),
        boxShadow: [
          BoxShadow(
            color: const Color(
              0xFF05081A,
            ).withValues(alpha: _Nav.sombre ? 0.28 : 0.08),
            blurRadius: 40,
            spreadRadius: -10,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}

class _Barre extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final lignes = <Widget>[];
    Groupe? groupe;
    for (var i = 0; i < liste.length; i++) {
      final d = liste[i];
      if (d.groupe != groupe) {
        groupe = d.groupe;
        lignes.add(
          Padding(
            padding: EdgeInsets.fromLTRB(14, lignes.isEmpty ? 2 : 14, 0, 6),
            child: Text(
              groupe.libelle,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _Nav.doux.withValues(alpha: 0.7),
              ),
            ),
          ),
        );
      }
      lignes.add(
        FadeUp(
          index: i,
          child: _LigneNav(
            destination: d,
            actif: i == actif,
            indicateur: resume == null ? null : d.indicateur?.call(resume!),
            onTap: () => onSelect(i),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: AtriumLockup(
              markSize: 40,
              hotelName: 'Hôtel Atrium',
              onNight: _Nav.sombre,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: lignes),
          ),
          const SizedBox(height: 8),
          _Compte(session: session, etendu: true),
        ],
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
  });

  final Destination destination;
  final bool actif;
  final VoidCallback onTap;
  final String? indicateur;

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
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 420));
    final encre = actif
        ? _Nav.encre
        : _Nav.doux.withValues(alpha: bientot ? 0.45 : 1);

    return MouseRegion(
      cursor: bientot ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _survol = true),
      onExit: (_) => setState(() => _survol = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: bientot ? null : widget.onTap,
        child: AnimatedContainer(
          duration: duree,
          curve: atriumSpring,
          height: 40,
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: actif
                ? _Nav.voile(0.09)
                : (_survol && !bientot
                      ? _Nav.voile(0.045)
                      : Colors.transparent),
            border: Border.all(
              color: actif ? _Nav.voile(0.08) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              AnimatedSwitcher(
                duration: duree,
                child: Icon(
                  actif ? d.iconActive : d.icon,
                  key: ValueKey(actif),
                  size: 21,
                  color: actif ? AtriumColors.mintStrong : encre,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedSlide(
                  duration: duree,
                  curve: atriumSpring,
                  offset: _survol && !actif && !bientot
                      ? const Offset(0.03, 0)
                      : Offset.zero,
                  child: Text(
                    d.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 14.5,
                      fontWeight: actif ? FontWeight.w700 : FontWeight.w500,
                      color: encre,
                    ),
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AtriumColors.mintStrong.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    widget.indicateur!,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: _Nav.sombre
                          ? const Color(0xFFFFC65A)
                          : AtriumPalette.current.tileMangoInk,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          const AtriumMark(size: 42),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (var i = 0; i < liste.length; i++)
                  if (liste[i].route != null)
                    _EntreeRail(
                      destination: liste[i],
                      actif: i == actif,
                      onTap: () => onSelect(i),
                    ),
              ],
            ),
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
                    color: actif
                        ? AtriumColors.mintStrong.withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(
                    actif ? destination.iconActive : destination.icon,
                    size: 21,
                    color: actif ? AtriumColors.mintStrong : _Nav.doux,
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
                    fontWeight: actif ? FontWeight.w800 : FontWeight.w600,
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
    final actifDansPlus = reste.contains(actif);

    return Scaffold(
      body: child,
      extendBody: true,
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            color: _Nav.fond,
            borderRadius: BorderRadius.circular(33),
            border: Border.all(color: _Nav.voile(0.07)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF05081A).withValues(alpha: 0.35),
                blurRadius: 30,
                spreadRadius: -8,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Row(
            children: [
              for (final i in onglets)
                Expanded(
                  child: _OngletTelephone(
                    label: liste[i].label,
                    icon: i == actif ? liste[i].iconActive : liste[i].icon,
                    actif: i == actif,
                    onTap: () => onSelect(i),
                  ),
                ),
              if (reste.isNotEmpty)
                Expanded(
                  child: _OngletTelephone(
                    label: 'Plus',
                    icon: PhosphorIconsLight.squaresFour,
                    actif: actifDansPlus,
                    onTap: () => _ouvrirPlus(context, reste),
                  ),
                ),
            ],
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
              width: actif ? 50 : 38,
              height: 30,
              decoration: BoxDecoration(
                color: actif ? _Nav.voile(0.10) : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(
                icon,
                size: 21,
                color: actif ? AtriumColors.mintStrong : _Nav.doux,
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
                color: actif ? _Nav.encre : _Nav.doux,
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
          tertiary: AtriumColors.mintStrong,
        ),
      ),
      child: const PendingWritesBadge(),
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
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
      decoration: BoxDecoration(
        color: _Nav.voile(0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _Nav.voile(0.06)),
      ),
      child: Row(
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
          // Les deux petits boutons l'un sur l'autre : cote a cote, ils
          // mangeaient le nom de l'agent.
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 36, child: BoutonTheme()),
              SizedBox(height: 36, child: synchro),
            ],
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

/// Les couleurs de la navigation. La nuit, une ile bleu-nuit ; le jour, une
/// ile de papier : un bloc violet sature sur une page claire ecrasait le
/// contenu et faisait deux applications en une.
abstract final class _Nav {
  static bool get sombre => AtriumPalette.current.isDark;
  static Color get fond =>
      sombre ? AtriumColors.purpleNight : AtriumPalette.current.paper;
  static Color get teinteHaut => sombre
      ? const Color(0xFF263178).withValues(alpha: 0.55)
      : AtriumPalette.current.accent.withValues(alpha: 0.05);
  static Color get encre =>
      sombre ? AtriumColors.onNight : AtriumPalette.current.text;
  static Color get doux =>
      sombre ? AtriumColors.onPurpleSoft : AtriumPalette.current.textSecondary;
  static Color voile(double a) => sombre
      ? Colors.white.withValues(alpha: a)
      : AtriumPalette.current.night.withValues(alpha: a * 0.8);
}
