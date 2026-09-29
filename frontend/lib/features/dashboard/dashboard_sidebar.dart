/// La barre laterale du tableau de bord.
///
/// Elle reprend les entrees de la maquette, chacune branchee sur l'ecran reel
/// qui lui correspond, et filtree par les droits de l'agent (3.4) : un
/// housekeeper n'a que faire des factures, et les lui montrer grises ne
/// l'aide pas. Le filtrage ici est un confort d'interface, pas une securite :
/// la vraie barriere est dans le routeur, qui refuse la route meme atteinte
/// autrement.
///
/// Trois formes selon la largeur : complete (icone et libelle), en rail
/// (icones seules, libelle en info-bulle), ou dans un tiroir sur les ecrans
/// etroits.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/tokens.dart';
import '../../data/local/queries/dashboard_queries.dart';
import '../auth/session.dart';

/// Une entree du menu.
class _Entree {
  const _Entree(
    this.libelle,
    this.icone,
    this.route,
    this.permission, {
    this.indicateur,
  });

  final String libelle;
  final IconData icone;

  /// `null` : module annonce mais pas encore livre.
  final String? route;

  /// `null` : ouvert a tous.
  final String? permission;

  /// Un chiffre du jour a afficher en bout de ligne.
  final String? Function(DashboardSummary)? indicateur;
}

/// Les entrees de la maquette, dans son ordre, plus « Factures » qu'elle
/// oubliait : sans elle, le module ne serait plus accessible depuis
/// l'accueil.
///
/// Arrivees et departs ouvrent les reservations, ou ils se traitent ; le CA
/// du jour ouvre les factures. Leurs chiffres restent sous les yeux en bout
/// de ligne pour les deux qui n'ont pas de carte au-dessus.
final _entrees = <_Entree>[
  const _Entree('Tableau de bord', Icons.grid_view_rounded, '/', null),
  const _Entree('Chambres', Icons.bed_outlined, '/chambres', 'rooms.read'),
  const _Entree(
    'Réservations',
    Icons.edit_calendar_outlined,
    '/reservations',
    'rooms.read',
  ),
  const _Entree('Arrivées', Icons.login_rounded, '/reservations', 'rooms.read'),
  const _Entree('Départs', Icons.logout_rounded, '/reservations', 'rooms.read'),
  _Entree(
    'CA du jour',
    Icons.point_of_sale_outlined,
    '/factures',
    'folio.read',
    indicateur: (r) => montantCompact(r.caDuJour),
  ),
  _Entree(
    'À nettoyer',
    Icons.cleaning_services_outlined,
    '/menage',
    'housekeeping.read',
    indicateur: (r) => '${r.chambresANettoyer}',
  ),
  const _Entree(
    'Plan des chambres',
    Icons.grid_view_outlined,
    '/chambres',
    'rooms.read',
  ),
  const _Entree(
    'Commandes',
    Icons.restaurant_outlined,
    '/commandes',
    'order.read',
  ),
  const _Entree('Maintenance', Icons.build_outlined, null, 'maintenance.read'),
  const _Entree(
    'Housekeeping',
    Icons.home_outlined,
    '/menage',
    'housekeeping.read',
  ),
  const _Entree('Clients', Icons.people_outline, '/clients', 'guests.read'),
  const _Entree(
    'Factures',
    Icons.receipt_long_outlined,
    '/factures',
    'folio.read',
  ),
];

/// Un montant en francs CFA qui tient en bout de ligne : `280 k`, `1,2 M`.
/// Le montant complet reste dans l'info-bulle.
String montantCompact(int montant) {
  final absolu = montant.abs();
  if (absolu < 1000) return '$montant';
  if (absolu < 1000000) return '${(montant / 1000).round()} k';
  final millions = (montant / 1000000).toStringAsFixed(1);
  return '${millions.replaceAll('.', ',')} M';
}

/// Vrai si l'agent a acces a au moins un module en plus de l'accueil.
bool aDesModules(SessionState session) => _entrees.any(
  (e) =>
      e.route != null &&
      e.route != '/' &&
      e.permission != null &&
      session.acces.peut(e.permission!),
);

class DashboardSidebar extends ConsumerWidget {
  const DashboardSidebar({
    super.key,
    required this.compacte,
    required this.resume,
    this.dansTiroir = false,
  });

  /// Rail d'icones plutot que liste complete.
  final bool compacte;
  final DashboardSummary? resume;

  /// Le tiroir se referme avant de naviguer.
  final bool dansTiroir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final visibles = _entrees
        .where((e) => e.permission == null || session.acces.peut(e.permission!))
        .toList();
    final haut = MediaQuery.paddingOf(context).top;

    return Container(
      width: compacte ? 88 : 272,
      color: AtriumDashColors.sidebar,
      child: Stack(
        children: [
          // La vague du bas, sous le profil : un rappel des rubans de la
          // page de connexion, en sourdine.
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 320,
            child: IgnorePointer(child: CustomPaint(painter: _Vague())),
          ),
          Column(
            children: [
              SizedBox(height: haut + (compacte ? 20 : 28)),
              _Logo(compacte: compacte),
              SizedBox(height: compacte ? 24 : 32),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.symmetric(horizontal: compacte ? 14 : 18),
                  children: [
                    for (final e in visibles)
                      _LigneNav(
                        entree: e,
                        active: e.route == '/',
                        compacte: compacte,
                        valeur: resume == null
                            ? null
                            : e.indicateur?.call(resume!),
                        onTap: e.route == null || e.route == '/'
                            ? null
                            : () {
                                if (dansTiroir) Navigator.of(context).pop();
                                context.go(e.route!);
                              },
                      ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: compacte ? 14 : 28),
                child: const Divider(
                  height: 1,
                  color: AtriumDashColors.sidebarDivider,
                ),
              ),
              _Profil(compacte: compacte, session: session),
              SizedBox(height: MediaQuery.paddingOf(context).bottom + 12),
            ],
          ),
        ],
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.compacte});

  final bool compacte;

  @override
  Widget build(BuildContext context) {
    final tuile = Container(
      width: compacte ? 52 : 64,
      height: compacte ? 52 : 64,
      decoration: BoxDecoration(
        color: AtriumDashColors.sidebarRaised,
        borderRadius: BorderRadius.circular(compacte ? 14 : 18),
        border: Border.all(color: AtriumColors.mintStrong, width: 1.5),
        boxShadow: AtriumShadows.glow(AtriumColors.mintStrong, force: 0.25),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.bed_outlined,
        color: AtriumColors.mint,
        size: compacte ? 26 : 32,
      ),
    );
    if (compacte) return Semantics(label: 'Atrium', child: tuile);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          tuile,
          const SizedBox(width: AtriumSpacing.md + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Atrium',
                  style: TextStyle(
                    fontSize: 28,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: AtriumColors.onNight,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Hotel Atrium',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AtriumDashColors.sidebarMuted,
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

class _LigneNav extends StatefulWidget {
  const _LigneNav({
    required this.entree,
    required this.active,
    required this.compacte,
    required this.valeur,
    required this.onTap,
  });

  final _Entree entree;
  final bool active;
  final bool compacte;
  final String? valeur;
  final VoidCallback? onTap;

  @override
  State<_LigneNav> createState() => _LigneNavState();
}

class _LigneNavState extends State<_LigneNav> {
  bool _survol = false;

  @override
  Widget build(BuildContext context) {
    final aVenir = widget.entree.route == null;
    final duree = AtriumMotion.of(context, AtriumMotion.fast);

    final contenu = AnimatedContainer(
      duration: duree,
      height: 52,
      padding: EdgeInsets.symmetric(horizontal: widget.compacte ? 0 : 16),
      decoration: BoxDecoration(
        gradient: widget.active
            ? LinearGradient(
                colors: [
                  AtriumDashColors.activeStart,
                  AtriumDashColors.activeEnd,
                ],
              )
            : null,
        color: widget.active
            ? null
            : (_survol && !aVenir
                  ? AtriumColors.onNight.withValues(alpha: 0.06)
                  : Colors.transparent),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.active
              ? AtriumDashColors.activeBorder.withValues(alpha: 0.7)
              : Colors.transparent,
        ),
        boxShadow: widget.active
            ? AtriumShadows.glow(AtriumDashColors.activeBorder, force: 0.25)
            : null,
      ),
      child: Row(
        mainAxisAlignment: widget.compacte
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          Icon(
            widget.entree.icone,
            size: 23,
            color: AtriumDashColors.sidebarText,
          ),
          if (!widget.compacte) ...[
            const SizedBox(width: AtriumSpacing.md),
            Expanded(
              child: Text(
                widget.entree.libelle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
                  color: AtriumDashColors.sidebarText,
                ),
              ),
            ),
            if (aVenir)
              Text(
                'à venir',
                style: TextStyle(
                  fontSize: 12,
                  color: AtriumDashColors.sidebarMuted,
                ),
              )
            else if (widget.valeur != null)
              Text(
                widget.valeur!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AtriumColors.mint,
                  fontFeatures: tabularFigures,
                ),
              ),
          ],
        ],
      ),
    );

    Widget ligne = Opacity(
      opacity: aVenir ? 0.5 : 1,
      child: MouseRegion(
        cursor: widget.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _survol = true),
        onExit: (_) => setState(() => _survol = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: contenu,
        ),
      ),
    );

    if (widget.compacte || aVenir || widget.valeur != null) {
      ligne = Tooltip(
        message: aVenir
            ? '${widget.entree.libelle} : module à venir'
            : widget.valeur == null
            ? widget.entree.libelle
            : '${widget.entree.libelle} : ${widget.valeur}',
        waitDuration: const Duration(milliseconds: 400),
        child: ligne,
      );
    }

    return Semantics(
      button: widget.onTap != null,
      selected: widget.active,
      enabled: !aVenir,
      label: widget.entree.libelle,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ExcludeSemantics(child: ligne),
      ),
    );
  }
}

/// L'agent connecte, et le menu qui permet de se deconnecter.
class _Profil extends ConsumerWidget {
  const _Profil({required this.compacte, required this.session});

  final bool compacte;
  final SessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = session.acces.roles.isEmpty
        ? 'Aucun rôle'
        : session.acces.roles.first;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compacte ? 14 : 24,
        AtriumSpacing.md,
        compacte ? 14 : 20,
        0,
      ),
      child: MenuCompte(
        session: session,
        child: Row(
          mainAxisAlignment: compacte
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            Avatar(session: session, taille: 44),
            if (!compacte) ...[
              const SizedBox(width: AtriumSpacing.sm + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.nomAffiche,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AtriumColors.onNight,
                      ),
                    ),
                    Text(
                      role,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: AtriumDashColors.sidebarMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AtriumColors.onNight,
                size: 24,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Le rond blanc aux initiales de l'agent.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.session, this.taille = 40});

  final SessionState session;
  final double taille;

  String get _initiales {
    final agent = session.agent;
    if (agent == null) return '?';
    final lettres = [agent.firstName, agent.lastName]
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .map((p) => p.characters.first.toUpperCase())
        .join();
    return lettres.isEmpty ? '?' : lettres;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: taille,
      height: taille,
      // Un disque mangue, initiales de nuit : lisible sur la barre laterale
      // comme sur le bandeau, en clair comme en sombre.
      decoration: BoxDecoration(
        color: AtriumColors.mintStrong,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        _initiales,
        style: TextStyle(
          fontSize: taille * 0.36,
          fontWeight: FontWeight.w800,
          color: AtriumColors.purpleNight,
        ),
      ),
    );
  }
}

/// Le menu du compte : qui est connecte, sous quels roles, et la sortie.
///
/// La deconnexion est l'operation la plus frequente de la journee sur une
/// tablette partagee : elle reste a une touche du profil, en bas de la barre
/// comme en haut a droite du bandeau.
class MenuCompte extends ConsumerWidget {
  const MenuCompte({super.key, required this.session, required this.child});

  final SessionState session;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Compte de ${session.nomAffiche}',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 8),
      color: AtriumColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AtriumRadii.lg),
      ),
      onSelected: (choix) {
        if (choix == 'sortir') {
          ref.read(sessionProvider.notifier).deconnecter();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.nomAffiche,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AtriumDashColors.title,
                ),
              ),
              Text(
                session.acces.roles.isEmpty
                    ? 'Compte rattaché à aucun rôle'
                    : session.acces.roles.join(', '),
                style: TextStyle(
                  fontSize: 13,
                  color: AtriumColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'sortir',
          child: Row(
            children: [
              Icon(Icons.logout_rounded, size: 20, color: AtriumColors.ink),
              SizedBox(width: AtriumSpacing.sm),
              Text('Se déconnecter'),
            ],
          ),
        ),
      ],
      child: child,
    );
  }
}

/// La vague sarcelle du bas de la barre.
class _Vague extends CustomPainter {
  const _Vague();

  @override
  void paint(Canvas canvas, Size taille) {
    final w = taille.width;
    final h = taille.height;
    final vague = Path()
      ..moveTo(0, h * 0.42)
      ..cubicTo(w * 0.35, h * 0.5, w * 0.6, h * 0.2, w, h * 0.08)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(
      vague,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            AtriumDashColors.activeStart.withValues(alpha: 0.28),
            AtriumDashColors.sidebar.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & taille),
    );
    // Un filet plus clair sur la crete, comme un reflet.
    final crete = Path()
      ..moveTo(0, h * 0.42)
      ..cubicTo(w * 0.35, h * 0.5, w * 0.6, h * 0.2, w, h * 0.08);
    canvas.drawPath(
      crete,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          colors: [
            AtriumColors.mintStrong.withValues(alpha: 0),
            AtriumColors.mintStrong.withValues(alpha: 0.35),
          ],
        ).createShader(Offset.zero & taille),
    );
  }

  @override
  bool shouldRepaint(_Vague ancien) => false;
}
