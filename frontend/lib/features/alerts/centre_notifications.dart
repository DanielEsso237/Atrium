/// Le centre de notifications (demande du 19 octobre) : une cloche sur
/// chaque ecran, ce qui est en cours, l'historique, et les commandes en
/// chambre.
///
/// Il part du centre d'alertes (`alert_center.dart`), qui calcule, sonne et
/// se souvient de ce que l'agent a vu : la cloche compte ses alertes non
/// vues, le panneau les montre toutes. Les commandes en chambre y ont leur
/// carte : le point de vente la prend en charge puis la livre sans quitter
/// l'ecran ou il est, la reception y suit celles qu'elle a passees.
///
/// Sur une tablette couchee, le panneau glisse depuis la droite et laisse
/// l'ecran dessous ; sur un telephone, il monte du bas.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/fenetre_motif.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/atrium_segmented_control.dart';
import '../../core/widgets/fiche_laterale.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/alert_queries.dart';
import '../../data/local/queries/historique_notifications_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/room_order_repository.dart';
import '../auth/session.dart';
import 'alert_center.dart';
import 'sonneries.dart' show iconeEvenement;

/// Ce qui a sonne ces sept derniers jours, pour l'agent connecte.
final historiqueNotificationsProvider =
    StreamProvider.autoDispose<List<NotificationPassee>>((ref) {
      final session = ref.watch(sessionProvider);
      if (!session.estConnecte) return Stream.value(const []);
      return ref
          .watch(databaseProvider)
          .watchHistoriqueNotifications(
            ContexteAlertes(
              agentId: session.agent?.id,
              peut: session.acces.peut,
              accueil: session.acces.homeRoute,
              maintenant: DateTime.now(),
            ),
          );
    });

/// Ouvre le panneau des notifications par-dessus l'ecran courant.
Future<void> ouvrirCentreNotifications(BuildContext context) =>
    afficherFicheLaterale<void>(
      context,
      libelleFermer: 'Fermer les notifications',
      fiche: (panneau) => FicheSurface(
        panneau: panneau,
        child: const _Panneau(),
      ),
    );

// --- La cloche ----------------------------------------------------------------

/// La cloche, en haut a droite de chaque ecran : le nombre d'alertes que
/// l'agent n'a pas encore vues, et le panneau au toucher.
///
/// Elle tinte quand ce nombre monte : c'est le seul mouvement qu'elle fait,
/// et il repond a quelque chose qui vient d'arriver.
class ClocheNotifications extends ConsumerStatefulWidget {
  const ClocheNotifications({super.key, this.couleur});

  /// La couleur de l'icone ; celle du texte par defaut.
  final Color? couleur;

  @override
  ConsumerState<ClocheNotifications> createState() =>
      _ClocheNotificationsState();
}

class _ClocheNotificationsState extends ConsumerState<ClocheNotifications>
    with SingleTickerProviderStateMixin {
  late final _tinte = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void dispose() {
    _tinte.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    ref.listen(centreAlertesProvider.select((e) => e.nonVues), (avant, n) {
      if (n > (avant ?? 0) && !MediaQuery.disableAnimationsOf(context)) {
        _tinte.forward(from: 0);
      }
    });
    final etat = ref.watch(centreAlertesProvider);
    final n = etat.nonVues;
    final critique = etat.actives.any(
      (a) => a.niveau == NiveauAlerte.critique && !etat.vues.contains(a.cle),
    );
    final libelle = n == 0
        ? 'Notifications'
        : 'Notifications, $n non vue${n > 1 ? 's' : ''}';

    return Semantics(
      button: true,
      label: libelle,
      excludeSemantics: true,
      child: Tooltip(
        message: libelle,
        child: InkResponse(
          onTap: () => ouvrirCentreNotifications(context),
          radius: 26,
          child: SizedBox.square(
            dimension: 48,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                AnimatedBuilder(
                  animation: _tinte,
                  builder: (_, icone) {
                    // Un balancement amorti, pendu par le haut, comme une
                    // vraie cloche.
                    final t = _tinte.value;
                    final angle =
                        math.sin(t * math.pi * 5) * (1 - t) * 0.32;
                    return Transform.rotate(
                      angle: angle,
                      alignment: const Alignment(0, -0.85),
                      child: icone,
                    );
                  },
                  child: Icon(
                    PhosphorIconsLight.bell,
                    size: 25,
                    color: widget.couleur ?? p.text,
                  ),
                ),
                if (n > 0)
                  Positioned(
                    top: 5,
                    right: 3,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 19),
                      height: 19,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: critique ? p.error : p.primary,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: p.paper, width: 2),
                      ),
                      child: Text(
                        n > 99 ? '99+' : '$n',
                        style: const TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1,
                          fontFeatures: tabularFigures,
                        ),
                      ),
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

// --- Le panneau et l'ecran ----------------------------------------------------

class _Panneau extends StatelessWidget {
  const _Panneau();

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return SafeArea(
      left: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Notifications',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Fermer les notifications',
                  onPressed: () => Navigator.of(context).pop(),
                  style: IconButton.styleFrom(
                    backgroundColor: p.surfaceMuted,
                    minimumSize: const Size.square(44),
                  ),
                  icon: Icon(PhosphorIconsLight.x, color: p.text, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: ContenuNotifications(
              // Le panneau se referme avant d'ouvrir l'ecran d'une alerte :
              // sinon il resterait par-dessus.
              avantDeNaviguer: () => Navigator.of(context).pop(),
              marge: 24,
            ),
          ),
        ],
      ),
    );
  }
}

/// L'ecran du centre de notifications : la ou mene une notification du
/// systeme, et le « Voir » du bandeau d'une commande en chambre.
class CentreNotificationsScreen extends StatelessWidget {
  const CentreNotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final etroit = MediaQuery.sizeOf(context).width < 600;
    return ModuleScaffold(
      title: 'Notifications',
      subtitle: 'Ce qui est en cours, et ce qui a sonné ces sept jours',
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ContenuNotifications(marge: etroit ? 18 : 32),
        ),
      ),
    );
  }
}

enum _Onglet { enCours, historique }

/// Le contenu commun au panneau et a l'ecran : deux onglets, En cours et
/// Historique.
class ContenuNotifications extends ConsumerStatefulWidget {
  const ContenuNotifications({
    super.key,
    this.avantDeNaviguer,
    this.marge = 24,
  });

  final VoidCallback? avantDeNaviguer;
  final double marge;

  @override
  ConsumerState<ContenuNotifications> createState() =>
      _ContenuNotificationsState();
}

class _ContenuNotificationsState extends ConsumerState<ContenuNotifications> {
  var _onglet = _Onglet.enCours;

  void _aller(String route) {
    final routeur = GoRouter.of(context);
    widget.avantDeNaviguer?.call();
    routeur.go(route);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final agentId = session.agent?.id;
    final acces = session.acces;
    final etat = ref.watch(centreAlertesProvider);
    final suivies = acces.peut('order.read') || acces.peut('room_order.create');
    final commandes = agentId == null || !suivies
        ? const <CommandeChambre>[]
        : ref.watch(commandesSuiviesProvider(agentId)).value ??
              const <CommandeChambre>[];
    // Une commande a sa carte : son alerte ne se repete pas dessous.
    final alertes = [
      for (final a in etat.actives)
        if (a.type != TypeEvenement.commandeChambre) a,
    ];
    final marge = widget.marge;

    final enCours = commandes.length + alertes.length;
    final contenu = switch (_onglet) {
      _Onglet.enCours => _EnCours(
        commandes: commandes,
        alertes: alertes,
        etat: etat,
        marge: marge,
        surVoir: _aller,
      ),
      _Onglet.historique => _Historique(marge: marge, surVoir: _aller),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(marge, 8, marge, 14),
          child: AtriumSegmentedControl<_Onglet>(
            segments: [
              AtriumSegment(
                value: _Onglet.enCours,
                label: enCours == 0 ? 'En cours' : 'En cours ($enCours)',
                icon: PhosphorIconsLight.bell,
              ),
              const AtriumSegment(
                value: _Onglet.historique,
                label: 'Historique',
                icon: PhosphorIconsLight.clockCounterClockwise,
              ),
            ],
            selected: _onglet,
            onChanged: (o) => setState(() => _onglet = o),
          ),
        ),
        Expanded(child: contenu),
      ],
    );
  }
}

// --- En cours -----------------------------------------------------------------

class _EnCours extends ConsumerWidget {
  const _EnCours({
    required this.commandes,
    required this.alertes,
    required this.etat,
    required this.marge,
    required this.surVoir,
  });

  final List<CommandeChambre> commandes;
  final List<Alerte> alertes;
  final EtatAlertes etat;
  final double marge;
  final ValueChanged<String> surVoir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (commandes.isEmpty && alertes.isEmpty) {
      return const EmptyState(
        icon: PhosphorIconsLight.checkCircle,
        title: 'Rien en cours',
        message:
            'Les alertes et les commandes en chambre s’affichent ici dès '
            'qu’elles arrivent.',
      );
    }
    final nonVues = alertes.where((a) => !etat.vues.contains(a.cle)).length;
    return ListView(
      padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
      children: [
        if (commandes.isNotEmpty) ...[
          _TitreSection(
            titre: 'Commandes en chambre',
            compte: commandes.length,
          ),
          for (final c in commandes)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: CarteCommandeChambre(
                key: ValueKey(c.id),
                commande: c,
                nouvelle: etat.actives.any(
                  (a) =>
                      a.cle == 'commande-${c.id}' &&
                      !etat.vues.contains(a.cle),
                ),
              ),
            ),
          const SizedBox(height: 12),
        ],
        if (alertes.isNotEmpty) ...[
          _TitreSection(
            titre: 'Alertes',
            compte: alertes.length,
            action: nonVues > 1
                ? TextButton(
                    onPressed: ref
                        .read(centreAlertesProvider.notifier)
                        .acquitterTout,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 44),
                    ),
                    child: const Text('Tout marquer comme vu'),
                  )
                : null,
          ),
          _Carte(
            children: [
              for (final a in alertes)
                _LigneAlerte(
                  alerte: a,
                  vue: etat.vues.contains(a.cle),
                  surVoir: surVoir,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _TitreSection extends StatelessWidget {
  const _TitreSection({required this.titre, this.compte, this.action});

  final String titre;
  final int? compte;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        children: [
          Text(
            titre,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          if (compte != null) ...[
            const SizedBox(width: 8),
            Text(
              '$compte',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
                fontFeatures: tabularFigures,
              ),
            ),
          ],
          const Spacer(),
          ?action,
        ],
      ),
    );
  }
}

/// Une carte blanche qui tient une liste, chaque ligne separee d'un filet.
class _Carte extends StatelessWidget {
  const _Carte({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AtriumDashColors.card,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AtriumDashColors.cardBorder),
    ),
    child: Column(
      children: [
        for (final (i, c) in children.indexed) ...[
          if (i > 0)
            Divider(height: 1, indent: 16, color: AtriumDashColors.cardBorder),
          c,
        ],
      ],
    ),
  );
}

class _LigneAlerte extends ConsumerWidget {
  const _LigneAlerte({
    required this.alerte,
    required this.vue,
    required this.surVoir,
  });

  final Alerte alerte;
  final bool vue;
  final ValueChanged<String> surVoir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final a = alerte;
    final couleur = switch (a.niveau) {
      NiveauAlerte.critique => p.error,
      NiveauAlerte.urgente => p.warning,
      NiveauAlerte.info => p.primary,
    };
    final centre = ref.read(centreAlertesProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: couleur.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(_icone(a.type), size: 19, color: couleur),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        a.titre,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 14.5,
                          fontWeight: vue ? FontWeight.w500 : FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                    ),
                    if (a.depuis case final d?) ...[
                      const SizedBox(width: 8),
                      Text(
                        heureNotification(d),
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 12.5,
                          color: p.textSecondary,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  a.corps,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13,
                    height: 1.35,
                    color: p.textSecondary,
                  ),
                ),
                if (!vue || a.route != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 4,
                      children: [
                        if (a.route case final route?)
                          TextButton(
                            onPressed: () {
                              centre.acquitter(a.cle);
                              surVoir(route);
                            },
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 40),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                            child: const Text('Voir'),
                          ),
                        if (!vue)
                          TextButton(
                            onPressed: () => centre.acquitter(a.cle),
                            style: TextButton.styleFrom(
                              foregroundColor: p.textSecondary,
                              minimumSize: const Size(48, 40),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                            child: const Text("J'ai vu"),
                          ),
                      ],
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

IconData _icone(TypeEvenement? type) =>
    type == null ? PhosphorIconsLight.envelopeSimple : iconeEvenement(type);

// --- La commande en chambre ---------------------------------------------------

/// Le porte-cle de la chambre, en laiton : c'est par son numero que le
/// plateau monte.
class _PorteCle extends StatelessWidget {
  const _PorteCle({required this.chambre});

  final String chambre;

  @override
  Widget build(BuildContext context) {
    final sombre = AtriumPalette.current.isDark;
    final fond = sombre ? const Color(0xFF2B2416) : const Color(0xFFF7EFDF);
    final encre = sombre ? AtriumPalette.brassOnBlue : const Color(0xFF6A4E17);
    final filet = AtriumPalette.brass.withValues(alpha: sombre ? 0.55 : 0.7);
    return Semantics(
      label: 'Chambre $chambre',
      excludeSemantics: true,
      child: Container(
        width: 58,
        height: 68,
        decoration: BoxDecoration(
          color: fond,
          border: Border.all(color: filet),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(22),
            bottom: Radius.circular(12),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 9),
            // L'oeillet du porte-cle.
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: filet, width: 1.5),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                child: Text(
                  chambre,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    color: encre,
                    height: 1,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Une commande en route : ce qu'il faut monter, a qui, depuis quand. Le
/// point de vente la prend en charge puis la livre ; qui l'a passee peut
/// l'annuler, avec un motif.
class CarteCommandeChambre extends ConsumerStatefulWidget {
  const CarteCommandeChambre({
    super.key,
    required this.commande,
    this.nouvelle = false,
  });

  final CommandeChambre commande;

  /// Son alerte n'est pas encore vue.
  final bool nouvelle;

  @override
  ConsumerState<CarteCommandeChambre> createState() =>
      _CarteCommandeChambreState();
}

class _CarteCommandeChambreState extends ConsumerState<CarteCommandeChambre> {
  Timer? _minute;
  bool _occupe = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    // « Il y a 12 min » doit vieillir avec la commande.
    _minute = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _minute?.cancel();
    super.dispose();
  }

  Future<void> _geste(Future<void> Function(String agent) geste) async {
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null || _occupe) return;
    setState(() {
      _occupe = true;
      _erreur = null;
    });
    try {
      await geste(agent);
      ref
          .read(centreAlertesProvider.notifier)
          .acquitter('commande-${widget.commande.id}');
    } on StateError catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _occupe = false);
    }
  }

  Future<void> _annuler() async {
    final c = widget.commande;
    final motif = await demanderMotif(
      context,
      titre: 'Annuler la commande de la chambre ${c.chambre ?? '?'}',
      libelleConfirmer: 'Annuler la commande',
      libelleRenoncer: 'Garder la commande',
      libelleMotif: 'Motif',
      indice: 'Le client s’est ravisé, article épuisé…',
      icone: PhosphorIconsLight.xCircle,
      danger: true,
      autofocus: true,
    );
    if (motif == null || !mounted) return;
    await _geste(
      (agent) => ref
          .read(roomOrderRepositoryProvider)
          .annuler(orderId: c.id, motif: motif, by: agent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final c = widget.commande;
    final acces = ref.watch(sessionProvider).acces;
    final servir = acces.peut('order.manage');
    final annuler = acces.peut('room_order.create') || servir;
    final aPrendre = c.statut == OrderStatus.SENT;
    final repo = ref.read(roomOrderRepositoryProvider);

    final texte = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 13.5,
      color: p.text,
      fontFeatures: tabularFigures,
    );
    final doux = texte.copyWith(color: p.textSecondary, fontSize: 13);

    final depuis = c.commandeeA == null
        ? null
        : DateTime.now().difference(c.commandeeA!.toLocal());
    final age = switch (depuis) {
      null => null,
      final d when d.inMinutes < 1 => 'à l’instant',
      final d when d.inMinutes < 60 => 'il y a ${d.inMinutes} min',
      final d => 'il y a ${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')}',
    };
    final commandee = [
      c.pointDeVente,
      if (c.commandeeA case final a?)
        'commandée à ${heureNotification(a)}'
            '${c.commandeePar == null ? '' : ' par ${c.commandeePar}'}',
    ].join(', ');

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: AtriumDashColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: widget.nouvelle
              ? p.warning.withValues(alpha: 0.55)
              : AtriumDashColors.cardBorder,
          width: widget.nouvelle ? 1.5 : 1,
        ),
        boxShadow: AtriumShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PorteCle(chambre: c.chambre ?? '?'),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          c.client ?? 'Chambre ${c.chambre ?? '?'}',
                          style: texte.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Tag(
                          aPrendre ? 'À prendre en charge' : 'En préparation',
                          color: aPrendre ? p.warning : p.primary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(commandee, style: doux),
                    if (!aPrendre && c.priseA != null)
                      Text(
                        'Prise en charge à ${heureNotification(c.priseA!)}'
                        '${c.prisePar == null ? '' : ' par ${c.prisePar}'}',
                        style: doux,
                      ),
                    if (age != null)
                      Text(
                        age,
                        style: doux.copyWith(
                          // Un plateau qui attend depuis un quart d'heure se
                          // voit.
                          color: (depuis?.inMinutes ?? 0) >= 15
                              ? p.warning
                              : p.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: AtriumDashColors.cardBorder),
          const SizedBox(height: 8),
          for (final l in c.lignes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 38,
                    child: Text(
                      '${l.quantite} ×',
                      style: texte.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.libelle, style: texte),
                        if (l.notes case final n? when n.trim().isNotEmpty)
                          Text('« ${n.trim()} »', style: doux),
                      ],
                    ),
                  ),
                  Text(formatAmount(l.montant), style: texte),
                ],
              ),
            ),
          if (c.notes case final n? when n.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Note : ${n.trim()}', style: doux),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('Total', style: texte.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                formatAmount(c.total),
                style: texte.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (servir || annuler) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (annuler)
                  TextButton(
                    onPressed: _occupe ? null : _annuler,
                    style: TextButton.styleFrom(
                      foregroundColor: p.error,
                      minimumSize: const Size(48, 44),
                    ),
                    child: const Text('Annuler'),
                  ),
                const Spacer(),
                if (servir)
                  PillButton(
                    label: aPrendre ? 'Prendre en charge' : 'Livrer',
                    icon: aPrendre
                        ? PhosphorIconsLight.handGrabbing
                        : PhosphorIconsLight.checkCircle,
                    tone: aPrendre ? PillTone.primary : PillTone.accent,
                    onPressed: _occupe
                        ? null
                        : () => _geste(
                            (agent) => aPrendre
                                ? repo.prendreEnCharge(
                                    orderId: c.id,
                                    by: agent,
                                  )
                                : repo.livrer(orderId: c.id, by: agent),
                          ),
                  ),
              ],
            ),
          ],
          if (_erreur case final e?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(PhosphorIconsLight.warningCircle, size: 17, color: p.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(e, style: doux.copyWith(color: p.error)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// --- L'historique -------------------------------------------------------------

class _Historique extends ConsumerWidget {
  const _Historique({required this.marge, required this.surVoir});

  final double marge;
  final ValueChanged<String> surVoir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final historique = ref.watch(historiqueNotificationsProvider);
    final liste = historique.value;
    if (liste == null) {
      return historique.hasError
          ? EmptyState(
              icon: PhosphorIconsLight.warningCircle,
              title: 'Lecture impossible',
              message: '${historique.error}',
            )
          : const Center(child: CircularProgressIndicator());
    }
    if (liste.isEmpty) {
      return const EmptyState(
        icon: PhosphorIconsLight.clockCounterClockwise,
        title: 'Rien ces sept derniers jours',
        message:
            'Les commandes en chambre, le ménage, les pannes et les '
            'transferts s’inscrivent ici avec leur issue.',
      );
    }

    // Rangees par journee hoteliere : une commande de 1 h du matin est
    // celle de la soiree d'hier.
    final jours = <DateTime, List<NotificationPassee>>{};
    for (final n in liste) {
      jours.putIfAbsent(businessDayFor(n.moment.toLocal()), () => []).add(n);
    }
    final aujourdhui = businessDayFor(DateTime.now());

    return ListView(
      padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
      children: [
        for (final MapEntry(key: jour, value: lignes) in jours.entries) ...[
          _TitreSection(titre: _libelleJour(jour, aujourdhui)),
          _Carte(
            children: [
              for (final n in lignes) _LigneHistorique(n: n, surVoir: surVoir),
            ],
          ),
          const SizedBox(height: 18),
        ],
        Text(
          'Les sept derniers jours. Les arrivées, les départs et les stocks '
          'ont leur propre historique, dans leur onglet.',
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 12.5,
            color: p.textSecondary,
          ),
        ),
      ],
    );
  }
}

const _joursSemaine = [
  'Lundi',
  'Mardi',
  'Mercredi',
  'Jeudi',
  'Vendredi',
  'Samedi',
  'Dimanche',
];

String _libelleJour(DateTime jour, DateTime aujourdhui) {
  final ecart = DateTime(aujourdhui.year, aujourdhui.month, aujourdhui.day)
      .difference(DateTime(jour.year, jour.month, jour.day))
      .inDays;
  if (ecart == 0) return 'Aujourd’hui';
  if (ecart == 1) return 'Hier';
  return '${_joursSemaine[jour.weekday - 1]} ${jour.day} '
      '${formatLongDate(jour).split(' ')[1]}';
}

class _LigneHistorique extends StatelessWidget {
  const _LigneHistorique({required this.n, required this.surVoir});

  final NotificationPassee n;
  final ValueChanged<String> surVoir;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final (couleur, icone) = switch (n.issue) {
      IssueNotification.reglee => (p.success, PhosphorIconsLight.checkCircle),
      IssueNotification.annulee => (p.textSecondary, PhosphorIconsLight.xCircle),
      IssueNotification.enCours => (p.warning, PhosphorIconsLight.clock),
      null => (p.textSecondary, PhosphorIconsLight.info),
    };
    final ligne = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Text(
              heureNotification(n.moment),
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 10),
            child: Icon(_icone(n.type), size: 18, color: p.textSecondary),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n.titre,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                if (n.detail.isNotEmpty)
                  Text(
                    n.detail,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13,
                      height: 1.35,
                      color: p.textSecondary,
                    ),
                  ),
                if (n.libelleIssue case final issue?)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      children: [
                        Icon(icone, size: 15, color: couleur),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            issue,
                            style: TextStyle(
                              fontFamily: atriumFontFamily,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: couleur,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final route = n.route;
    if (route == null || route == routeCentreNotifications) return ligne;
    return InkWell(onTap: () => surVoir(route), child: ligne);
  }
}
