/// La coque de l'application : la navigation, toujours au meme endroit.
///
/// Avant, chaque ecran avait sa fleche retour vers le tableau de bord, seul
/// endroit ou vivait le menu : pour passer des reservations au menage, il
/// fallait repasser par l'accueil. La coque garde la navigation visible
/// partout, sous trois formes selon la largeur :
///
/// - **PC** (>= 1100) : barre laterale de nuit, le contenu pose sur un
///   panneau arrondi, comme une feuille sur un bureau ;
/// - **tablette** (>= 600) : un rail d'icones de nuit, toujours a portee du
///   pouce gauche ;
/// - **telephone** : une barre d'onglets en bas, et « Plus » pour le reste.
///
/// Les entrees sont filtrees par les droits de l'agent (3.4). Ce filtrage est
/// un confort : la vraie barriere reste dans le routeur.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/session.dart';
import '../../features/dashboard/dashboard_sidebar.dart' show Avatar, MenuCompte;
import '../brand/atrium_logo.dart';
import '../tokens.dart';
import '../widgets/module_scaffold.dart' show PendingWritesBadge;

class Destination {
  const Destination(
    this.label,
    this.icon,
    this.iconActive,
    this.route,
    this.permission,
  );

  final String label;
  final IconData icon;
  final IconData iconActive;
  final String route;

  /// `null` : ouverte a tous.
  final String? permission;
}

const destinations = <Destination>[
  Destination(
    "Aujourd'hui",
    Icons.wb_sunny_outlined,
    Icons.wb_sunny_rounded,
    '/',
    null,
  ),
  Destination(
    'Chambres',
    Icons.king_bed_outlined,
    Icons.king_bed_rounded,
    '/chambres',
    'rooms.read',
  ),
  Destination(
    'Réservations',
    Icons.event_note_outlined,
    Icons.event_note_rounded,
    '/reservations',
    'rooms.read',
  ),
  Destination(
    'Clients',
    Icons.people_outline_rounded,
    Icons.people_rounded,
    '/clients',
    'guests.read',
  ),
  Destination(
    'Ménage',
    Icons.cleaning_services_outlined,
    Icons.cleaning_services_rounded,
    '/menage',
    'housekeeping.read',
  ),
  Destination(
    'Restaurant',
    Icons.restaurant_outlined,
    Icons.restaurant_rounded,
    '/commandes',
    'order.read',
  ),
  Destination(
    'Factures',
    Icons.receipt_long_outlined,
    Icons.receipt_long_rounded,
    '/factures',
    'folio.read',
  ),
  Destination(
    'Statistiques',
    Icons.insights_outlined,
    Icons.insights_rounded,
    '/statistiques',
    null,
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
    final r = liste[i].route;
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

    void aller(int i) => context.go(liste[i].route);

    if (largeur >= 1100) {
      return _Cadre(
        barre: _BarreLaterale(
          liste: liste,
          actif: actif,
          onSelect: aller,
          session: session,
        ),
        child: child,
      );
    }
    if (largeur >= 600) {
      return _Cadre(
        barre: _Rail(
          liste: liste,
          actif: actif,
          onSelect: aller,
          session: session,
        ),
        child: child,
      );
    }
    return _CadreTelephone(
      liste: liste,
      actif: actif,
      onSelect: aller,
      session: session,
      child: child,
    );
  }
}

/// PC et tablette : la nuit tout autour, le contenu sur un panneau arrondi.
class _Cadre extends StatelessWidget {
  const _Cadre({required this.barre, required this.child});

  final Widget barre;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // `Material` et non un simple fond : les boutons, info-bulles et le
    // badge de synchro de la barre en ont besoin, et c'est lui qui donne au
    // texte son style (sans lui, Flutter souligne tout en jaune).
    return Material(
      color: AtriumColors.purpleNight,
      child: SafeArea(
        child: Row(
          children: [
            barre,
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: ColoredBox(
                    color: AtriumColors.background,
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarreLaterale extends StatelessWidget {
  const _BarreLaterale({
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
    return SizedBox(
      width: 252,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: AtriumLockup(markSize: 42, hotelName: 'Hôtel Atrium'),
            ),
            const SizedBox(height: 30),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (var i = 0; i < liste.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _LigneNav(
                        destination: liste[i],
                        actif: i == actif,
                        onTap: () => onSelect(i),
                      ),
                    ),
                ],
              ),
            ),
            const _EtatSynchro(etendu: true),
            const SizedBox(height: 10),
            _Compte(session: session, etendu: true),
          ],
        ),
      ),
    );
  }
}

class _LigneNav extends StatefulWidget {
  const _LigneNav({
    required this.destination,
    required this.actif,
    required this.onTap,
  });

  final Destination destination;
  final bool actif;
  final VoidCallback onTap;

  @override
  State<_LigneNav> createState() => _LigneNavState();
}

class _LigneNavState extends State<_LigneNav> {
  bool _survol = false;

  @override
  Widget build(BuildContext context) {
    final actif = widget.actif;
    final duree = AtriumMotion.of(context, AtriumMotion.base);
    return MouseRegion(
      onEnter: (_) => setState(() => _survol = true),
      onExit: (_) => setState(() => _survol = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: duree,
          curve: Curves.easeOutCubic,
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: actif
                ? AtriumDashColors.activeStart
                : (_survol
                      ? AtriumColors.onNight.withValues(alpha: 0.06)
                      : Colors.transparent),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              AnimatedSwitcher(
                duration: duree,
                child: Icon(
                  actif ? widget.destination.iconActive : widget.destination.icon,
                  key: ValueKey(actif),
                  size: 23,
                  color: actif
                      ? AtriumDashColors.activeBorder
                      : AtriumColors.onPurpleSoft,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  widget.destination.label,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15.5,
                    fontWeight: actif ? FontWeight.w700 : FontWeight.w500,
                    color: actif
                        ? AtriumColors.onNight
                        : AtriumColors.onPurpleSoft,
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
    return SizedBox(
      width: 92,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          children: [
            const AtriumMark(size: 44),
            const SizedBox(height: 22),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (var i = 0; i < liste.length; i++)
                    _EntreeRail(
                      destination: liste[i],
                      actif: i == actif,
                      onTap: () => onSelect(i),
                    ),
                ],
              ),
            ),
            const _EtatSynchro(etendu: false),
            const SizedBox(height: 8),
            _Compte(session: session, etendu: false),
          ],
        ),
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
    final duree = AtriumMotion.of(context, AtriumMotion.base);
    return Semantics(
      button: true,
      selected: actif,
      label: destination.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              AnimatedContainer(
                duration: duree,
                curve: Curves.easeOutCubic,
                width: 58,
                height: 38,
                decoration: BoxDecoration(
                  color: actif
                      ? AtriumDashColors.activeStart
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(19),
                ),
                child: Icon(
                  actif ? destination.iconActive : destination.icon,
                  size: 24,
                  color: actif
                      ? AtriumDashColors.activeBorder
                      : AtriumColors.onPurpleSoft,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 11.5,
                  fontWeight: actif ? FontWeight.w700 : FontWeight.w500,
                  color: actif
                      ? AtriumColors.onNight
                      : AtriumColors.onPurpleSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Telephone : le contenu plein ecran, les onglets dans une barre de nuit
/// flottante en bas. Au-dela de quatre modules, « Plus » ouvre le reste.
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
    // Un metier a un seul ecran n'a pas besoin de barre du tout.
    if (liste.length <= 1) return child;

    final deborde = liste.length > _visibles + 1;
    final onglets = deborde ? liste.take(_visibles).toList() : liste;
    final actifDansPlus = deborde && actif >= _visibles;

    return Scaffold(
      body: child,
      extendBody: true,
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            color: AtriumColors.purpleNight,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF05081A).withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              for (var i = 0; i < onglets.length; i++)
                Expanded(
                  child: _OngletTelephone(
                    label: onglets[i].label,
                    icon: i == actif ? onglets[i].iconActive : onglets[i].icon,
                    actif: i == actif,
                    onTap: () => onSelect(i),
                  ),
                ),
              if (deborde)
                Expanded(
                  child: _OngletTelephone(
                    label: 'Plus',
                    icon: Icons.apps_rounded,
                    actif: actifDansPlus,
                    onTap: () => _ouvrirPlus(context),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _ouvrirPlus(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (feuille) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = _visibles; i < liste.length; i++)
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
                  icon: const Icon(Icons.logout_rounded),
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
    final duree = AtriumMotion.of(context, AtriumMotion.base);
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
              curve: Curves.easeOutCubic,
              width: actif ? 52 : 40,
              height: 30,
              decoration: BoxDecoration(
                color: actif ? AtriumDashColors.activeStart : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(
                icon,
                size: 22,
                color: actif
                    ? AtriumDashColors.activeBorder
                    : AtriumColors.onPurpleSoft,
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
                color: actif ? AtriumColors.onNight : AtriumColors.onPurpleSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// L'etat des echanges, visible en permanence en bas de la barre.
class _EtatSynchro extends StatelessWidget {
  const _EtatSynchro({required this.etendu});

  final bool etendu;

  @override
  Widget build(BuildContext context) {
    return Theme(
      // Le badge prend ses couleurs dans le theme : on lui donne celles de la
      // nuit pour qu'il reste lisible sur la barre.
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(context).colorScheme.copyWith(
          onSurfaceVariant: AtriumColors.onPurpleSoft,
          tertiary: AtriumColors.mintStrong,
        ),
      ),
      child: etendu
          ? Row(
              children: [
                const PendingWritesBadge(),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Synchronisation',
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13,
                      color: AtriumColors.onPurpleSoft,
                    ),
                  ),
                ),
              ],
            )
          : const PendingWritesBadge(),
    );
  }
}

class _Compte extends StatelessWidget {
  const _Compte({required this.session, required this.etendu});

  final SessionState session;
  final bool etendu;

  @override
  Widget build(BuildContext context) {
    final role = session.acces.roles.isEmpty ? 'Agent' : session.acces.roles.first;
    return MenuCompte(
      session: session,
      child: etendu
          ? Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AtriumColors.onNight.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Avatar(session: session, taille: 38),
                  const SizedBox(width: 12),
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
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: AtriumColors.onNight,
                          ),
                        ),
                        Text(
                          role,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 12.5,
                            color: AtriumColors.onPurpleSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.unfold_more_rounded,
                    size: 20,
                    color: AtriumColors.onPurpleSoft,
                  ),
                ],
              ),
            )
          : Avatar(session: session, taille: 42),
    );
  }
}
