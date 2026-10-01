/// Tableau de bord (cahier des charges, paragraphe 5.1).
///
/// Le premier ecran apres la connexion, et le seul que tout le monde voit quel
/// que soit son role. Il reprend la maquette validee : une barre laterale de
/// nuit, un bandeau d'accueil ouvert sur une chambre, quatre cartes chiffrees
/// avec leur tendance, puis l'occupation, la repartition des chambres,
/// l'activite de la journee et les derniers evenements.
///
/// Tout vient de la base locale, en flux continu (voir `dashboard_queries`) :
/// quand la reception fait un check-in, les chiffres et les courbes bougent
/// sans que personne ne rafraichisse, en ligne comme hors ligne.
library;

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/dashboard_queries.dart';
import '../auth/session.dart';
import '../../core/widgets/atrium_bandeau.dart';
import '../../core/widgets/atrium_puces.dart';
import 'dashboard_charts.dart';
import 'dashboard_sidebar.dart';

final dashboardProvider = StreamProvider<DashboardSummary>(
  (ref) => ref.watch(databaseProvider).watchDashboard(),
);

/// L'historique des `jours` derniers jours.
final historiqueProvider = StreamProvider.family<List<JourneeStats>, int>(
  (ref, jours) => ref.watch(databaseProvider).watchHistorique(jours: jours),
);

final repartitionProvider = StreamProvider<List<RepartitionType>>(
  (ref) => ref.watch(databaseProvider).watchRepartition(),
);

final activiteDuJourProvider = StreamProvider<ActiviteHoraire>(
  (ref) => ref.watch(databaseProvider).watchActiviteDuJour(),
);

final dernieresActivitesProvider = StreamProvider<List<Activite>>(
  (ref) => ref.watch(databaseProvider).watchDernieresActivites(limite: 30),
);

final notificationsNonLuesProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchNotificationsNonLues(),
);

final notificationsProvider = StreamProvider<List<NotificationResume>>(
  (ref) => ref.watch(databaseProvider).watchNotifications(),
);

/// La periode du graphique d'occupation, en jours.
///
/// Un `Notifier` et non un `StateProvider` : celui-ci a disparu en Riverpod 3.
class PeriodeOccupation extends Notifier<int> {
  @override
  int build() => 7;

  void choisir(int jours) => state = jours;
}

final periodeOccupationProvider = NotifierProvider<PeriodeOccupation, int>(
  PeriodeOccupation.new,
);

/// Construit une fois : `ThemeData` n'est pas gratuit.
final _theme = atriumBrandTheme();

const _photoChambre = 'assets/images/chambre.jpg';

/// La barre laterale : masquee par defaut, ouverte a la demande par le
/// bouton du bandeau. L'etat tient le temps de la session : revenir au tableau
/// de bord depuis un module la retrouve comme on l'a laissee.
class BarreLaterale extends Notifier<bool> {
  @override
  bool build() => false;

  void basculer() => state = !state;
}

final barreLateraleProvider = NotifierProvider<BarreLaterale, bool>(
  BarreLaterale.new,
);

/// Largeur a partir de laquelle la barre pousse le contenu au lieu de
/// passer par-dessus : en dessous, lui prendre 272 points ecraserait les
/// cartes.
const _largeurPousse = 1024.0;

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with SingleTickerProviderStateMixin {
  /// L'unique mouvement que l'agent ne declenche pas : les chiffres qui
  /// montent, les courbes qui se tracent, l'anneau qui se referme. Une seule
  /// sequence a l'arrivee ; ensuite, rien ne bouge sans raison.
  late final _entree = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final _phases = _Phases(_entree);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    precacheImage(const AssetImage(_photoChambre), context);
    if (_entree.isAnimating || _entree.isCompleted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _entree.value = 1;
    } else {
      _entree.forward();
    }
  }

  @override
  void dispose() {
    _phases.dispose();
    _entree.dispose();
    super.dispose();
  }

  final _cleScaffold = GlobalKey<ScaffoldState>();

  /// Etat du tiroir sur les ecrans etroits, tenu par le Scaffold : c'est lui
  /// qui le ferme quand on touche le voile ou qu'on le fait glisser.
  bool _tiroirOuvert = false;

  void _basculer(bool pousse) {
    if (pousse) {
      ref.read(barreLateraleProvider.notifier).basculer();
      return;
    }
    final scaffold = _cleScaffold.currentState;
    if (scaffold == null) return;
    scaffold.isDrawerOpen ? scaffold.closeDrawer() : scaffold.openDrawer();
  }

  @override
  Widget build(BuildContext context) {
    final largeur = MediaQuery.sizeOf(context).width;
    final pousse = largeur >= _largeurPousse;
    final ouverte = ref.watch(barreLateraleProvider);
    final resume = ref.watch(dashboardProvider).value;
    final menuOuvert = pousse ? ouverte : _tiroirOuvert;

    return Theme(
      data: _theme,
      // Icones de la barre d'etat en blanc quand la barre de nuit est a
      // gauche, en sombre sur le bandeau clair.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value:
            (pousse && ouverte
                    ? SystemUiOverlayStyle.light
                    : SystemUiOverlayStyle.dark)
                .copyWith(statusBarColor: Colors.transparent),
        child: Scaffold(
          key: _cleScaffold,
          backgroundColor: AtriumDashColors.page,
          drawer: pousse
              ? null
              : Drawer(
                  width: 288,
                  backgroundColor: AtriumDashColors.sidebar,
                  shape: const RoundedRectangleBorder(),
                  child: DashboardSidebar(
                    compacte: false,
                    resume: resume,
                    dansTiroir: true,
                  ),
                ),
          onDrawerChanged: (ouvert) => setState(() => _tiroirOuvert = ouvert),
          body: Row(
            children: [
              if (pousse) _BarreGlissante(ouverte: ouverte, resume: resume),
              Expanded(
                child: _Contenu(
                  phases: _phases,
                  menuOuvert: menuOuvert,
                  onMenu: () => _basculer(pousse),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La barre qui glisse depuis la gauche et pousse le contenu.
///
/// Repliee, elle reste dans l'arbre pour que l'ouverture soit un glissement
/// et non une apparition ; mais elle ne recoit alors ni toucher, ni focus
/// clavier, ni lecture d'ecran.
class _BarreGlissante extends StatelessWidget {
  const _BarreGlissante({required this.ouverte, required this.resume});

  final bool ouverte;
  final DashboardSummary? resume;

  static const _largeur = 272.0;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AtriumMotion.of(context, const Duration(milliseconds: 340)),
      curve: Curves.easeOutCubic,
      width: ouverte ? _largeur : 0,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerRight,
          minWidth: _largeur,
          maxWidth: _largeur,
          child: IgnorePointer(
            ignoring: !ouverte,
            child: ExcludeFocus(
              excluding: !ouverte,
              child: ExcludeSemantics(
                excluding: !ouverte,
                child: DashboardSidebar(compacte: false, resume: resume),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Les intervalles de la sequence d'entree, crees une fois.
class _Phases {
  _Phases(AnimationController c)
    : kpi = [
        for (var i = 0; i < 4; i++)
          CurvedAnimation(
            parent: c,
            curve: Interval(
              0.05 + 0.07 * i,
              0.5 + 0.07 * i,
              curve: Curves.easeOutCubic,
            ),
          ),
      ],
      occupation = CurvedAnimation(
        parent: c,
        curve: const Interval(0.3, 0.9, curve: Curves.easeInOutCubic),
      ),
      anneau = CurvedAnimation(
        parent: c,
        curve: const Interval(0.35, 0.95, curve: Curves.easeOutCubic),
      ),
      barres = CurvedAnimation(
        parent: c,
        curve: const Interval(0.45, 1, curve: Curves.easeOutBack),
      );

  final List<CurvedAnimation> kpi;
  final CurvedAnimation occupation;
  final CurvedAnimation anneau;
  final CurvedAnimation barres;

  void dispose() {
    for (final a in [...kpi, occupation, anneau, barres]) {
      a.dispose();
    }
  }
}

// --- Contenu -----------------------------------------------------------------

class _Contenu extends ConsumerWidget {
  const _Contenu({
    required this.phases,
    required this.menuOuvert,
    required this.onMenu,
  });

  final _Phases phases;
  final bool menuOuvert;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final resume = ref.watch(dashboardProvider);

    return Stack(
      children: [
        // La vague menthe du coin bas droit, fixe sous le defilement.
        const Positioned(
          right: 0,
          bottom: 0,
          width: 420,
          height: 240,
          child: IgnorePointer(child: CustomPaint(painter: _VagueCoin())),
        ),
        SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Bandeau(menuOuvert: menuOuvert, onMenu: onMenu),
              LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  final marge = w >= 900 ? 32.0 : (w >= 560 ? 24.0 : 16.0);
                  final interieur = w - 2 * marge;
                  final deuxColonnes = interieur >= 860;
                  const ecart = 22.0;

                  return Padding(
                    padding: EdgeInsets.fromLTRB(marge, 24, marge, 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!aDesModules(session)) ...[
                          const _AucunModule(),
                          const SizedBox(height: ecart),
                        ],
                        resume.when(
                          loading: () => _LigneKpi.attente(
                            colonnes: _colonnesKpi(interieur),
                          ),
                          error: (e, _) => _Erreur(message: '$e'),
                          data: (r) => _LigneKpi(
                            resume: r,
                            colonnes: _colonnesKpi(interieur),
                            phases: phases.kpi,
                          ),
                        ),
                        const SizedBox(height: ecart),
                        _Rangee(
                          deuxColonnes: deuxColonnes,
                          hauteur: 340,
                          gauche: _CarteOccupation(
                            resume: resume.value,
                            progres: phases.occupation,
                          ),
                          droite: _CarteRepartition(
                            occupees: resume.value?.chambresOccupees ?? 0,
                            progres: phases.anneau,
                          ),
                        ),
                        const SizedBox(height: ecart),
                        _Rangee(
                          deuxColonnes: deuxColonnes,
                          hauteur: 316,
                          gauche: _CarteActivite(progres: phases.barres),
                          droite: const _CarteDernieres(),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Quatre cartes de front tant que chacune garde 236 points : en dessous,
  /// leurs titres se tronquaient.
  int _colonnesKpi(double largeur) {
    if ((largeur - 3 * 22) / 4 >= 236) return 4;
    return largeur >= 520 ? 2 : 1;
  }
}

/// Deux cartes cote a cote (62 / 38 comme la maquette), ou l'une sous l'autre
/// quand la place manque.
class _Rangee extends StatelessWidget {
  const _Rangee({
    required this.deuxColonnes,
    required this.hauteur,
    required this.gauche,
    required this.droite,
  });

  final bool deuxColonnes;
  final double hauteur;
  final Widget gauche;
  final Widget droite;

  @override
  Widget build(BuildContext context) {
    if (!deuxColonnes) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: hauteur, child: gauche),
          const SizedBox(height: 22),
          SizedBox(height: hauteur, child: droite),
        ],
      );
    }
    return SizedBox(
      height: hauteur,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 62, child: gauche),
          const SizedBox(width: 22),
          Expanded(flex: 38, child: droite),
        ],
      ),
    );
  }
}

// --- Bandeau d'accueil -------------------------------------------------------

class _Bandeau extends ConsumerWidget {
  const _Bandeau({required this.menuOuvert, required this.onMenu});

  final bool menuOuvert;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final haut = MediaQuery.paddingOf(context).top;

    final prenom = session.agent?.firstName.trim() ?? '';
    final heure = DateTime.now().hour;
    // « Bonsoir » passe 18 h : le service de nuit ouvre aussi cet ecran.
    final salut = heure >= 18 || heure < 5 ? 'Bonsoir' : 'Bonjour';
    final titre = prenom.isEmpty ? salut : '$salut, $prenom';

    return LayoutBuilder(
      builder: (context, c) {
        // Trois dispositions : tout sur une ligne quand la place le permet ;
        // les pastilles sous l'accueil sur une tablette ; sur un telephone,
        // les boutons en haut et l'accueil sur toute la largeur.
        final uneLigne = c.maxWidth >= 1060;
        final telephone = c.maxWidth < 600;
        final etroit = !uneLigne;

        final salutation = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    titre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: etroit ? 24 : 30,
                      fontWeight: FontWeight.w700,
                      color: AtriumDashColors.title,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Une icone et non un emoji : sans police emoji embarquee,
                // une tablette hors ligne affichait un carre vide.
                ExcludeSemantics(
                  child: Icon(
                    Icons.waving_hand,
                    size: etroit ? 24 : 30,
                    color: AtriumDashColors.wave,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "Voici un aperçu de l'activité de votre hôtel aujourd'hui.",
              style: TextStyle(
                fontSize: etroit ? 14 : 16,
                color: AtriumColors.textSecondary,
                height: 1.4,
              ),
            ),
          ],
        );

        const puces = [_PuceDate(), PuceEtatConnexion(), PuceEcritures()];
        final bouton = _BoutonMenu(ouvert: menuOuvert, onTap: onMenu);

        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Cloche(),
            const SizedBox(width: AtriumSpacing.md),
            MenuCompte(
              session: session,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Avatar(session: session, taille: 42),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.expand_more_rounded,
                    color: AtriumColors.white,
                    size: 26,
                  ),
                ],
              ),
            ),
          ],
        );

        // Une hauteur minimale et non fixe : sur un ecran etroit, ou quand
        // les pastilles prennent de la place, le sous-titre passe sur deux
        // lignes et debordait du bandeau.
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: haut + (etroit ? 150 : 172)),
          child: Stack(
            children: [
              const Positioned.fill(child: AtriumBandeauFond()),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  telephone ? 12 : 24,
                  haut + (etroit ? 16 : 26),
                  etroit ? 16 : 28,
                  20,
                ),
                child: uneLigne
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bouton,
                          const SizedBox(width: AtriumSpacing.lg),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: salutation,
                            ),
                          ),
                          const SizedBox(width: AtriumSpacing.md),
                          const Wrap(
                            spacing: AtriumSpacing.md,
                            runSpacing: AtriumSpacing.xs,
                            children: puces,
                          ),
                          const SizedBox(width: AtriumSpacing.xxl + 8),
                          actions,
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (telephone) ...[
                            Row(children: [bouton, const Spacer(), actions]),
                            const SizedBox(height: AtriumSpacing.sm),
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: salutation,
                            ),
                          ] else
                            Row(
                              children: [
                                bouton,
                                const SizedBox(width: AtriumSpacing.md),
                                Expanded(child: salutation),
                                const SizedBox(width: AtriumSpacing.md),
                                actions,
                              ],
                            ),
                          const SizedBox(height: AtriumSpacing.md),
                          Padding(
                            padding: EdgeInsets.only(
                              left: telephone ? 4 : 44 + AtriumSpacing.md,
                            ),
                            child: const Wrap(
                              spacing: AtriumSpacing.sm,
                              runSpacing: AtriumSpacing.xs,
                              children: puces,
                            ),
                          ),
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

/// Le bouton du menu : trois traits de longueurs inegales, qui s'alignent au
/// survol et se croisent en X quand la barre est ouverte.
///
/// La croix dit ce que fera le prochain appui -- refermer -- sans qu'il faille
/// regarder a gauche si la barre est la.
class _BoutonMenu extends StatefulWidget {
  const _BoutonMenu({required this.ouvert, required this.onTap});

  final bool ouvert;
  final VoidCallback onTap;

  @override
  State<_BoutonMenu> createState() => _BoutonMenuState();
}

class _BoutonMenuState extends State<_BoutonMenu> {
  bool _survol = false;

  @override
  Widget build(BuildContext context) {
    final libelle = widget.ouvert ? 'Masquer le menu' : 'Afficher le menu';
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 340));
    final rayon = BorderRadius.circular(AtriumRadii.md);

    return Semantics(
      button: true,
      expanded: widget.ouvert,
      label: libelle,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: Tooltip(
        message: libelle,
        waitDuration: const Duration(milliseconds: 500),
        child: MouseRegion(
          onEnter: (_) => setState(() => _survol = true),
          onExit: (_) => setState(() => _survol = false),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AtriumColors.white,
              borderRadius: rayon,
              boxShadow: AtriumShadows.soft,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: widget.onTap,
                borderRadius: rayon,
                child: SizedBox.square(
                  dimension: 44,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: widget.ouvert ? 1 : 0),
                    duration: duree,
                    curve: Curves.easeInOutCubic,
                    builder: (context, ouverture, _) =>
                        TweenAnimationBuilder<double>(
                          tween: Tween(end: _survol ? 1 : 0),
                          duration: AtriumMotion.of(context, AtriumMotion.base),
                          curve: AtriumMotion.standard,
                          builder: (context, survol, _) => CustomPaint(
                            painter: _TroisTraits(
                              ouverture: ouverture,
                              survol: survol,
                            ),
                          ),
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TroisTraits extends CustomPainter {
  const _TroisTraits({required this.ouverture, required this.survol});

  /// 0 : trois traits ; 1 : une croix.
  final double ouverture;

  /// 0 : longueurs inegales ; 1 : alignees.
  final double survol;

  static const _largeur = 20.0;
  static const _ecart = 6.0;

  @override
  void paint(Canvas canvas, Size taille) {
    final centre = taille.center(Offset.zero);
    final t = ouverture;
    final egalise = math.max(survol, t);
    final trait = Paint()
      ..color = AtriumDashColors.title
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    // Un trait part du bord gauche ; au repos il est plus ou moins court,
    // ouvert il fait toute la largeur et tourne autour du centre.
    void tracer(double repos, double decalage, double angle, double opacite) {
      if (opacite <= 0) return;
      final longueur = lerpDouble(repos, _largeur, egalise)!;
      canvas.save();
      canvas.translate(centre.dx, centre.dy + decalage * (1 - t));
      canvas.rotate(angle * t);
      canvas.drawLine(
        const Offset(-_largeur / 2, 0),
        Offset(-_largeur / 2 + longueur, 0),
        trait..color = AtriumDashColors.title.withValues(alpha: opacite),
      );
      canvas.restore();
    }

    tracer(_largeur, -_ecart, math.pi / 4, 1);
    tracer(_largeur * 0.6 * (1 - t), 0, 0, 1 - t);
    tracer(_largeur * 0.8, _ecart, -math.pi / 4, 1);
  }

  @override
  bool shouldRepaint(_TroisTraits ancien) =>
      ancien.ouverture != ouverture || ancien.survol != survol;
}

/// La journee **hoteliere**, celle dont parlent les chiffres, et non la date
/// du calendrier. Entre minuit et six heures les deux different : afficher le
/// 25 au-dessus de compteurs qui parlent du 24 fait lire une remise a zero la
/// ou il n'y en a pas. Quand elles different, on le dit, sinon l'ecart
/// passerait pour une erreur.
class _PuceDate extends StatelessWidget {
  const _PuceDate();

  @override
  Widget build(BuildContext context) {
    final maintenant = DateTime.now();
    final journee = businessDayFor(maintenant);
    final decalee = journee.day != maintenant.day;

    final puce = AtriumPuce(
      icone: Icons.calendar_month_outlined,
      child: decalee
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatLongDate(journee)),
                const Text(
                  'service de nuit',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AtriumColors.textSecondary,
                  ),
                ),
              ],
            )
          : Text(formatLongDate(journee)),
    );

    if (!decalee) return puce;
    return Tooltip(
      message:
          "La journée hôtelière court jusqu'à 6 h. Les chiffres sont ceux de "
          'cette journée, pas de la date du calendrier.',
      child: puce,
    );
  }
}

/// La cloche : un point menthe s'il reste des notifications non lues.
class _Cloche extends ConsumerWidget {
  const _Cloche();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nonLues = ref.watch(notificationsNonLuesProvider).value ?? 0;

    return IconButton(
      tooltip: nonLues == 0
          ? 'Notifications'
          : '$nonLues notification${nonLues > 1 ? 's' : ''} non lue'
                '${nonLues > 1 ? 's' : ''}',
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => const _Notifications(),
      ),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(
            Icons.notifications_none_rounded,
            size: 28,
            color: AtriumColors.white,
          ),
          if (nonLues > 0)
            Positioned(
              right: 1,
              top: 1,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: AtriumColors.mintStrong,
                  shape: BoxShape.circle,
                  border: Border.all(color: AtriumColors.white, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Notifications extends ConsumerWidget {
  const _Notifications();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liste = ref.watch(notificationsProvider).value ?? const [];

    return AlertDialog(
      title: const Text('Notifications'),
      content: SizedBox(
        width: 420,
        child: liste.isEmpty
            ? const Text(
                'Aucune notification pour le moment.',
                style: TextStyle(color: AtriumColors.textSecondary),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: liste.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final n = liste[i];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      n.titre,
                      style: TextStyle(
                        fontWeight: n.lue ? FontWeight.w500 : FontWeight.w700,
                      ),
                    ),
                    subtitle: n.corps == null ? null : Text(n.corps!),
                    trailing: Text(
                      _heure(n.moment),
                      style: const TextStyle(
                        fontSize: 13,
                        color: AtriumColors.textSecondary,
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}

// --- Cartes chiffrees --------------------------------------------------------

class _LigneKpi extends ConsumerWidget {
  const _LigneKpi({
    required this.resume,
    required this.colonnes,
    required this.phases,
  });

  const _LigneKpi.attente({required this.colonnes})
    : resume = null,
      phases = const [];

  final DashboardSummary? resume;
  final int colonnes;
  final List<Animation<double>> phases;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = resume;
    final acces = ref.watch(sessionProvider).acces;
    final historique = ref.watch(historiqueProvider(7)).value;
    List<int> serie(int Function(JourneeStats) f, [int? aujourdhui]) {
      if (historique == null || historique.isEmpty) return List.filled(7, 0);
      final valeurs = [for (final j in historique) f(j)];
      // Le dernier point parle comme la carte au-dessus, pas comme la
      // requete d'historique : une chambre dont le client part aujourd'hui
      // est encore occupee tant qu'il n'a pas rendu la cle.
      if (aujourdhui != null) valeurs[valeurs.length - 1] = aujourdhui;
      return valeurs;
    }

    final versReservations = acces.peut('rooms.read') ? '/reservations' : null;

    final cartes = r == null
        ? [for (var i = 0; i < 4; i++) const _CarteKpi.attente()]
        : [
            _CarteKpi(
              titre: 'Chambres',
              icone: Icons.bed_outlined,
              teinte: _Teinte.menthe,
              valeur: (t) =>
                  '${(r.chambresOccupees * t).round()} / ${r.chambresTotal}',
              detail: r.tauxOccupation == null
                  ? 'aucune chambre paramétrée'
                  : "${r.tauxOccupation} % d'occupation",
              fleche: Icons.north_east_rounded,
              flecheAccent: true,
              route: acces.peut('rooms.read') ? '/chambres' : null,
              tendance: serie((j) => j.occupees, r.chambresOccupees),
              descriptionTendance: 'Chambres occupées',
              progres: phases[0],
            ),
            _CarteKpi(
              titre: 'Réservations',
              icone: Icons.edit_calendar_outlined,
              teinte: _Teinte.lavande,
              valeur: (t) => '${(r.reservationsActives * t).round()}',
              detail: 'en cours',
              route: versReservations,
              tendance: serie((j) => j.reservations),
              descriptionTendance: 'Réservations en séjour',
              progres: phases[1],
            ),
            _CarteKpi(
              titre: 'Arrivées',
              icone: Icons.login_rounded,
              teinte: _Teinte.menthe,
              valeur: (t) => '${(r.arriveesDuJour * t).round()}',
              // Le total de la journee en chiffre, ce qui reste a faire en
              // dessous. Un compteur qui retombe a zero a mesure qu'on
              // travaille se lit comme une panne.
              detail: r.arriveesRestantes == 0
                  ? 'toutes enregistrées'
                  : '${r.arriveesRestantes} encore attendue'
                        '${r.arriveesRestantes > 1 ? 's' : ''}',
              route: versReservations,
              tendance: serie((j) => j.arrivees, r.arriveesDuJour),
              descriptionTendance: 'Arrivées',
              progres: phases[2],
            ),
            _CarteKpi(
              titre: 'Départs',
              icone: Icons.logout_rounded,
              teinte: _Teinte.lavande,
              valeur: (t) => '${(r.departsDuJour * t).round()}',
              detail: r.departsRestants == 0
                  ? 'tous enregistrés'
                  : '${r.departsRestants} encore à faire',
              route: versReservations,
              tendance: serie((j) => j.departs, r.departsDuJour),
              descriptionTendance: 'Départs',
              progres: phases[3],
            ),
          ];

    const ecart = 22.0;
    final lignes = <Widget>[];
    for (var i = 0; i < cartes.length; i += colonnes) {
      final rangee = cartes.skip(i).take(colonnes).toList();
      lignes.add(
        SizedBox(
          height: 172,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var k = 0; k < rangee.length; k++) ...[
                if (k > 0) const SizedBox(width: ecart),
                Expanded(child: rangee[k]),
              ],
            ],
          ),
        ),
      );
      if (i + colonnes < cartes.length) {
        lignes.add(const SizedBox(height: ecart));
      }
    }
    return Column(children: lignes);
  }
}

enum _Teinte { menthe, lavande, bleu }

extension on _Teinte {
  Color get fond => switch (this) {
    _Teinte.menthe => AtriumDashColors.tileMint,
    _Teinte.lavande => AtriumDashColors.tileLavender,
    _Teinte.bleu => AtriumDashColors.tileBlue,
  };

  Color get encre => switch (this) {
    _Teinte.menthe => AtriumDashColors.tileMintInk,
    _Teinte.lavande => AtriumDashColors.tileLavenderInk,
    _Teinte.bleu => AtriumDashColors.tileBlueInk,
  };

  Color get serie => switch (this) {
    _Teinte.menthe => AtriumChartColors.current,
    _Teinte.lavande || _Teinte.bleu => AtriumChartColors.previous,
  };
}

/// La tuile d'icone des cartes : fond pale, pictogramme soutenu.
class _Tuile extends StatelessWidget {
  const _Tuile({required this.icone, required this.teinte, this.taille = 56});

  final IconData icone;
  final _Teinte teinte;
  final double taille;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        color: teinte.fond,
        borderRadius: BorderRadius.circular(taille * 0.28),
      ),
      alignment: Alignment.center,
      child: Icon(icone, size: taille * 0.5, color: teinte.encre),
    );
  }
}

/// Le cadre commun des cartes : fond blanc, filet, voile d'ombre.
class _Cadre extends StatelessWidget {
  const _Cadre({required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AtriumDashColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AtriumDashColors.cardBorder),
        boxShadow: AtriumShadows.soft,
      ),
      child: child,
    );
  }
}

class _CarteKpi extends StatelessWidget {
  const _CarteKpi({
    required this.titre,
    required this.icone,
    required this.teinte,
    required this.valeur,
    required this.detail,
    required this.route,
    required this.tendance,
    required this.descriptionTendance,
    required this.progres,
    this.fleche = Icons.arrow_forward_rounded,
    this.flecheAccent = false,
  });

  const _CarteKpi.attente()
    : titre = '',
      icone = Icons.hourglass_empty_rounded,
      teinte = _Teinte.bleu,
      valeur = null,
      detail = '',
      route = null,
      tendance = const [],
      descriptionTendance = '',
      progres = const AlwaysStoppedAnimation(1),
      fleche = Icons.arrow_forward_rounded,
      flecheAccent = false;

  final String titre;
  final IconData icone;
  final _Teinte teinte;

  /// Le chiffre, a une etape `t` de la montee d'entree (0 a 1).
  final String Function(double t)? valeur;
  final String detail;
  final IconData fleche;

  /// La fleche menthe de la premiere carte, comme la maquette.
  final bool flecheAccent;

  /// L'ecran ou mene la fleche, ou `null` si l'agent n'y a pas acces.
  final String? route;
  final List<int> tendance;
  final String descriptionTendance;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context) {
    if (valeur == null) {
      return const _Cadre(
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AtriumColors.mintStrong,
            ),
          ),
        ),
      );
    }

    return _Cadre(
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 70,
            child: Sparkline(
              valeurs: tendance,
              couleur: teinte.serie,
              progres: progres,
              description: descriptionTendance,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Tuile(icone: icone, teinte: teinte, taille: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          titre,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AtriumDashColors.title,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      AnimatedBuilder(
                        animation: progres,
                        builder: (context, _) => FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            valeur!(progres.value.clamp(0.0, 1.0)),
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              color: AtriumDashColors.title,
                              height: 1.1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          detail,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AtriumColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (route != null)
                  _Fleche(icone: fleche, accent: flecheAccent, route: route!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Fleche extends StatelessWidget {
  const _Fleche({
    required this.icone,
    required this.accent,
    required this.route,
  });

  final IconData icone;
  final bool accent;
  final String route;

  @override
  Widget build(BuildContext context) {
    final menthe = accent;
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        tooltip: 'Ouvrir',
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: menthe
              ? AtriumColors.mintTint
              : AtriumDashColors.control,
          minimumSize: const Size(34, 34),
        ),
        iconSize: 18,
        color: menthe ? AtriumDashColors.tileMintInk : AtriumDashColors.title,
        icon: Icon(icone),
        onPressed: () => context.go(route),
      ),
    );
  }
}

// --- Cartes de section -------------------------------------------------------

/// Une carte a titre : tuile d'icone, titre, et une action a droite.
class _Section extends StatelessWidget {
  const _Section({
    required this.titre,
    required this.icone,
    required this.teinte,
    required this.child,
    this.action,
  });

  final String titre;
  final IconData icone;
  final _Teinte teinte;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return _Cadre(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Tuile(icone: icone, teinte: teinte, taille: 42),
              const SizedBox(width: AtriumSpacing.md),
              Expanded(
                child: Text(
                  titre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AtriumDashColors.title,
                  ),
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: AtriumSpacing.md),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Le bouton « ... » des cartes : un menu d'actions reelles.
class _MenuPoints extends StatelessWidget {
  const _MenuPoints({required this.actions});

  final List<(String, IconData, String)> actions;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: "Plus d'actions",
      position: PopupMenuPosition.under,
      color: AtriumColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AtriumRadii.lg),
      ),
      onSelected: (route) => context.go(route),
      itemBuilder: (_) => [
        for (final (libelle, icone, route) in actions)
          PopupMenuItem(
            value: route,
            child: Row(
              children: [
                Icon(icone, size: 20, color: AtriumColors.ink),
                const SizedBox(width: AtriumSpacing.sm),
                Text(libelle),
              ],
            ),
          ),
      ],
      child: Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(
          color: AtriumDashColors.control,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.more_horiz_rounded,
          size: 20,
          color: AtriumDashColors.title,
        ),
      ),
    );
  }
}

class _CarteOccupation extends ConsumerWidget {
  const _CarteOccupation({required this.resume, required this.progres});

  final DashboardSummary? resume;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periode = ref.watch(periodeOccupationProvider);
    final historique = ref.watch(historiqueProvider(periode * 2)).value;
    final total = resume?.chambresTotal ?? 0;

    int taux(int occupees) =>
        total == 0 ? 0 : (occupees * 100 / total).round().clamp(0, 100);

    final Widget corps;
    if (historique == null || historique.length < periode * 2) {
      corps = const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: AtriumColors.mintStrong,
        ),
      );
    } else {
      final precedent = historique.take(periode).toList();
      final actuel = historique.skip(periode).toList();
      final valeursActuelles = [for (final j in actuel) taux(j.occupees)];
      // Aujourd'hui parle comme la carte « Chambres » : l'info-bulle et la
      // carte ne peuvent pas donner deux taux differents.
      if (resume?.tauxOccupation != null) {
        valeursActuelles[valeursActuelles.length - 1] = resume!.tauxOccupation!;
      }
      final (libelleActuel, libellePrecedent) = periode == 7
          ? ('Cette semaine', 'Semaine précédente')
          : ('$periode derniers jours', '$periode jours précédents');

      corps = OccupationChart(
        jours: [for (final j in actuel) j.jour],
        actuel: valeursActuelles,
        precedent: [for (final j in precedent) taux(j.occupees)],
        progres: progres,
        libelleActuel: libelleActuel,
        libellePrecedent: libellePrecedent,
      );
    }

    return _Section(
      titre: "Taux d'occupation",
      icone: Icons.data_usage_rounded,
      teinte: _Teinte.bleu,
      action: PopupMenuButton<int>(
        tooltip: 'Période',
        initialValue: periode,
        position: PopupMenuPosition.under,
        color: AtriumColors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtriumRadii.lg),
        ),
        onSelected: ref.read(periodeOccupationProvider.notifier).choisir,
        itemBuilder: (_) => [
          for (final j in const [7, 14, 30])
            PopupMenuItem(value: j, child: Text('$j jours')),
        ],
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AtriumDashColors.control,
            borderRadius: BorderRadius.circular(19),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$periode jours',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AtriumDashColors.title,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.expand_more_rounded,
                size: 20,
                color: AtriumDashColors.title,
              ),
            ],
          ),
        ),
      ),
      child: corps,
    );
  }
}

class _CarteRepartition extends ConsumerWidget {
  const _CarteRepartition({required this.occupees, required this.progres});

  final int occupees;
  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = ref.watch(repartitionProvider).value;
    final acces = ref.watch(sessionProvider).acces;

    return _Section(
      titre: 'Répartition des chambres',
      icone: Icons.donut_small_outlined,
      teinte: _Teinte.menthe,
      action: acces.peut('rooms.read')
          ? const _MenuPoints(
              actions: [
                (
                  'Ouvrir le plan des chambres',
                  Icons.grid_view_outlined,
                  '/chambres',
                ),
              ],
            )
          : null,
      child: types == null
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AtriumColors.mintStrong,
              ),
            )
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: RepartitionDonut(
                types: types,
                occupees: occupees,
                progres: progres,
              ),
            ),
    );
  }
}

class _CarteActivite extends ConsumerWidget {
  const _CarteActivite({required this.progres});

  final Animation<double> progres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activite = ref.watch(activiteDuJourProvider).value;
    final acces = ref.watch(sessionProvider).acces;
    final maintenant = DateTime.now();
    // La tranche en cours n'a de sens que pour la journee affichee.
    final courante = trancheHoraire(maintenant.hour);

    return _Section(
      titre: 'Activité du jour',
      icone: Icons.groups_2_outlined,
      teinte: _Teinte.lavande,
      action: acces.peut('rooms.read')
          ? const _MenuPoints(
              actions: [
                (
                  'Voir les réservations',
                  Icons.edit_calendar_outlined,
                  '/reservations',
                ),
              ],
            )
          : null,
      child: activite == null
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AtriumColors.mintStrong,
              ),
            )
          : ActiviteBarres(
              activite: activite,
              trancheCourante: courante,
              progres: progres,
            ),
    );
  }
}

class _CarteDernieres extends ConsumerWidget {
  const _CarteDernieres();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activites = ref.watch(dernieresActivitesProvider).value;

    return _Section(
      titre: 'Dernières activités',
      icone: Icons.calendar_month_outlined,
      teinte: _Teinte.lavande,
      action: activites == null || activites.isEmpty
          ? null
          : TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _ToutesActivites(activites: activites),
              ),
              style: TextButton.styleFrom(
                backgroundColor: AtriumDashColors.control,
                foregroundColor: AtriumDashColors.tileLavenderInk,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 38),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Voir tout'),
                  SizedBox(width: 6),
                  Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
            ),
      child: activites == null
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AtriumColors.mintStrong,
              ),
            )
          : activites.isEmpty
          ? const Center(
              child: Text(
                'Rien pour le moment. Réservations, arrivées, départs et '
                'commandes apparaîtront ici.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: AtriumColors.textSecondary,
                ),
              ),
            )
          : LayoutBuilder(
              builder: (context, c) {
                // Autant de lignes que la carte en tient, sans couper la
                // derniere en deux.
                final nombre = ((c.maxHeight + 1) / 53).floor().clamp(
                  1,
                  activites.length,
                );
                return Column(
                  children: [
                    for (var i = 0; i < nombre; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, color: AtriumDashColors.grid),
                      _LigneActivite(activite: activites[i]),
                    ],
                  ],
                );
              },
            ),
    );
  }
}

class _ToutesActivites extends StatelessWidget {
  const _ToutesActivites({required this.activites});

  final List<Activite> activites;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Dernières activités'),
      content: SizedBox(
        width: 480,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: activites.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: AtriumDashColors.grid),
          itemBuilder: (_, i) => _LigneActivite(activite: activites[i]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}

class _LigneActivite extends StatelessWidget {
  const _LigneActivite({required this.activite});

  final Activite activite;

  @override
  Widget build(BuildContext context) {
    final a = activite;
    final (titre, icone, teinte) = switch (a.genre) {
      GenreActivite.reservation => (
        'Nouvelle réservation',
        Icons.event_available_outlined,
        _Teinte.menthe,
      ),
      GenreActivite.arrivee => (
        'Arrivée enregistrée',
        Icons.login_rounded,
        _Teinte.menthe,
      ),
      GenreActivite.depart => (
        'Départ effectué',
        Icons.logout_rounded,
        _Teinte.lavande,
      ),
      GenreActivite.commande => (
        'Commande ${a.pointDeVente?.toLowerCase() ?? 'restaurant'}',
        Icons.restaurant_outlined,
        _Teinte.bleu,
      ),
    };
    final lieu = a.chambre != null
        ? 'Chambre ${a.chambre}'
        : (a.typeChambre != null ? 'Chambre ${a.typeChambre}' : null);
    final detail = [lieu, a.client].whereType<String>().join(' · ');

    return SizedBox(
      height: 52,
      child: Row(
        children: [
          _Tuile(icone: icone, teinte: teinte, taille: 40),
          const SizedBox(width: AtriumSpacing.md),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AtriumDashColors.title,
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AtriumColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AtriumSpacing.sm),
          Text(
            _heure(a.moment),
            style: const TextStyle(
              fontSize: 13,
              color: AtriumColors.textSecondary,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}

/// L'heure d'un evenement du jour, « Hier » pour la veille, la date au-dela.
String _heure(DateTime instant) {
  final local = instant.toLocal();
  final journee = businessDayFor(DateTime.now());
  final jourEvenement = businessDayFor(local);
  if (jourEvenement == journee) {
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
  if (journee.difference(jourEvenement).inDays == 1) return 'Hier';
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}';
}

// --- Etats particuliers ------------------------------------------------------

/// Un agent sans aucun rattachement : le dire, plutot que de laisser une barre
/// vide qui se lit comme une panne.
class _AucunModule extends StatelessWidget {
  const _AucunModule();

  @override
  Widget build(BuildContext context) {
    return const _Cadre(
      padding: EdgeInsets.all(20),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, color: AtriumColors.textSecondary),
          SizedBox(width: AtriumSpacing.md),
          Expanded(
            child: Text(
              "Aucun module ne vous est ouvert : votre compte n'est rattaché "
              "à aucun rôle. Demandez à l'administrateur de le faire.",
              style: TextStyle(fontSize: 15, color: AtriumColors.ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _Erreur extends StatelessWidget {
  const _Erreur({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _Cadre(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AtriumColors.error, size: 28),
          const SizedBox(width: AtriumSpacing.md),
          Expanded(
            child: Text(
              'Lecture de la base impossible.\n$message',
              style: const TextStyle(fontSize: 15, color: AtriumColors.ink),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Decors ------------------------------------------------------------------

/// La vague menthe du coin bas droit de la page.
class _VagueCoin extends CustomPainter {
  const _VagueCoin();

  @override
  void paint(Canvas canvas, Size taille) {
    final w = taille.width;
    final h = taille.height;
    final vague = Path()
      ..moveTo(w, h * 0.15)
      ..cubicTo(w * 0.8, h * 0.45, w * 0.55, h * 0.7, w * 0.25, h)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(
      vague,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomRight,
          end: Alignment.topLeft,
          colors: [
            AtriumColors.mint.withValues(alpha: 0.55),
            AtriumColors.mint.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & taille),
    );
  }

  @override
  bool shouldRepaint(_VagueCoin ancien) => false;
}
