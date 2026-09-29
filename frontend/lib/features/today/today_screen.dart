/// Aujourd'hui : l'ecran de travail de la reception.
///
/// Pas un tableau de chiffres a contempler, mais la journee a traiter : qui
/// arrive, qui part, ou en est l'hotel. Chaque ligne porte son action (le
/// check-in, le check-out, l'attribution d'une chambre).
///
/// Grille bento asymetrique : l'occupation en grande carte, les quatre
/// chiffres du jour a cote, puis les mouvements et l'hotel chambre par
/// chambre. Une colonne sur telephone. Donnees : la base locale, comme
/// partout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/ui/icons.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';
import '../auth/session.dart';
import '../dashboard/dashboard_screen.dart' show dashboardProvider;
import '../reservations/assign_room_dialog.dart';
import '../reservations/stay_actions.dart';
import '../rooms/room_board_screen.dart' show apparence, roomBoardProvider;
import '../rooms/room_detail_panel.dart';

final _sejoursVivantsProvider = StreamProvider<List<ReservationSummary>>(
  (ref) => ref
      .watch(reservationRepositoryProvider)
      .watchReservations(
        statuses: {
          ReservationStatus.PENDING,
          ReservationStatus.CONFIRMED,
          ReservationStatus.CHECKED_IN,
        },
      ),
);

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final jour = businessDayFor(DateTime.now());
    final iso = formatIsoDate(jour);
    final sejours = ref.watch(_sejoursVivantsProvider).value ?? const [];
    final arrivees = [
      for (final s in sejours)
        if (s.arrival == iso && s.status != ReservationStatus.CHECKED_IN) s,
    ];
    final departs = [
      for (final s in sejours)
        if (s.departure == iso && s.status == ReservationStatus.CHECKED_IN) s,
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final large = c.maxWidth >= 900;
        final marge = c.maxWidth < 600 ? 18.0 : 36.0;
        final gap = large ? 18.0 : 14.0;

        final entete = _EnTete(
          prenom: session.agent?.firstName ?? '',
          jour: jour,
          peutReserver: session.acces.peut('rooms.read'),
        );
        const occupation = _Occupation();
        const chiffres = _Chiffres();
        final blocArrivees = _BlocSejours(
          titre: 'Arrivées',
          icone: PhosphorIconsLight.signIn,
          vide: "Plus personne n'est attendu aujourd'hui.",
          sejours: arrivees,
          depart: false,
        );
        final blocDeparts = _BlocSejours(
          titre: 'Départs',
          icone: PhosphorIconsLight.signOut,
          vide: "Plus aucun départ prévu aujourd'hui.",
          sejours: departs,
          depart: true,
        );
        const hotel = _BlocHotel();

        final blocs = large
            ? [
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Expanded(
                        flex: 11,
                        child: FadeUp(index: 1, child: occupation),
                      ),
                      SizedBox(width: gap),
                      const Expanded(
                        flex: 9,
                        child: FadeUp(index: 2, child: chiffres),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: gap),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: FadeUp(index: 3, child: blocArrivees)),
                    SizedBox(width: gap),
                    Expanded(child: FadeUp(index: 4, child: blocDeparts)),
                  ],
                ),
                SizedBox(height: gap),
                const FadeUp(index: 5, child: hotel),
              ]
            : [
                const FadeUp(index: 1, child: occupation),
                SizedBox(height: gap),
                const FadeUp(index: 2, child: chiffres),
                SizedBox(height: gap),
                FadeUp(index: 3, child: blocArrivees),
                SizedBox(height: gap),
                FadeUp(index: 4, child: blocDeparts),
                SizedBox(height: gap),
                const FadeUp(index: 5, child: hotel),
              ];

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(marge, large ? 40 : 24, marge, 120),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              // Sur un grand ecran, la page ne s'etire pas a l'infini.
              constraints: const BoxConstraints(maxWidth: 1320),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FadeUp(child: entete),
                  SizedBox(height: large ? 32 : 22),
                  ...blocs,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EnTete extends StatelessWidget {
  const _EnTete({
    required this.prenom,
    required this.jour,
    required this.peutReserver,
  });

  final String prenom;
  final DateTime jour;
  final bool peutReserver;

  @override
  Widget build(BuildContext context) {
    final heure = DateTime.now().hour;
    final salut = heure >= 18 || heure < 5 ? 'Bonsoir' : 'Bonjour';
    final etroit = MediaQuery.sizeOf(context).width < 600;

    return Wrap(
      spacing: 20,
      runSpacing: 18,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatLongDate(jour),
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AtriumColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$salut${prenom.isEmpty ? '' : ','} '),
                  TextSpan(
                    text: prenom,
                    style: TextStyle(color: AtriumColors.mintStrong),
                  ),
                ],
              ),
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: etroit ? 32 : 46,
                fontWeight: FontWeight.w800,
                letterSpacing: etroit ? -1 : -1.8,
                height: 1.02,
                color: AtriumColors.textPrimary,
              ),
            ),
          ],
        ),
        if (peutReserver)
          PillButton(
            label: 'Nouvelle réservation',
            icon: PhosphorIconsLight.plus,
            onPressed: () => context.go('/reservations/nouvelle'),
          ),
      ],
    );
  }
}

/// L'occupation : le chiffre en grand, et la repartition reelle des
/// chambres par etat, en une barre segmentee qui se deploie.
class _Occupation extends ConsumerWidget {
  const _Occupation();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chambres = ref.watch(roomBoardProvider).value ?? const [];
    final total = chambres.length;
    final parEtat = <RoomDisplayStatus, int>{};
    for (final c in chambres) {
      parEtat.update(c.displayStatus, (n) => n + 1, ifAbsent: () => 1);
    }
    final occupees = parEtat[RoomDisplayStatus.OCCUPIED] ?? 0;
    final taux = total == 0 ? 0 : (occupees * 100 / total).round();
    final p = AtriumPalette.current;

    return Bezel(
      padding: const EdgeInsets.fromLTRB(26, 24, 26, 24),
      core: p.night,
      onTap: () => context.go('/chambres'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Occupation ce soir',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: p.onNightSoft,
                ),
              ),
              const Spacer(),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  PhosphorIconsLight.arrowUpRight,
                  size: 17,
                  color: p.onNight,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _Compteur(
                valeur: occupees,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 84,
                  height: 0.9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -4,
                  color: p.onNight,
                  fontFeatures: tabularFigures,
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'sur $total chambres',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: p.onNight,
                      ),
                    ),
                    Text(
                      '$taux % du parc',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: p.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          _BarreEtats(parEtat: parEtat, total: total),
          const SizedBox(height: 14),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              for (final etat in RoomDisplayStatus.values)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: apparence(etat).couleur,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${apparence(etat).label} ${parEtat[etat] ?? 0}',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: p.onNightSoft,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Un nombre qui compte jusqu'a sa valeur a l'ouverture.
class _Compteur extends StatelessWidget {
  const _Compteur({required this.valeur, required this.style});

  final int valeur;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: valeur.toDouble()),
      duration: AtriumMotion.of(context, const Duration(milliseconds: 1100)),
      curve: atriumSpring,
      builder: (_, v, _) => Text('${v.round()}', style: style),
    );
  }
}

class _BarreEtats extends StatelessWidget {
  const _BarreEtats({required this.parEtat, required this.total});

  final Map<RoomDisplayStatus, int> parEtat;
  final int total;

  @override
  Widget build(BuildContext context) {
    if (total == 0) return const SizedBox(height: 12);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AtriumMotion.of(context, const Duration(milliseconds: 1200)),
      curve: atriumSpring,
      builder: (_, t, _) => ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: SizedBox(
          height: 12,
          child: Row(
            children: [
              for (final etat in RoomDisplayStatus.values)
                if ((parEtat[etat] ?? 0) > 0)
                  Expanded(
                    flex: (parEtat[etat]! * 1000 * t).round().clamp(1, 1 << 30),
                    child: Container(
                      margin: const EdgeInsets.only(right: 2),
                      color: apparence(etat).couleur,
                    ),
                  ),
              Expanded(
                flex: (total * 1000 * (1 - t)).round().clamp(0, 1 << 30) + 1,
                child: const SizedBox(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Les quatre chiffres du jour, en grille 2 x 2.
class _Chiffres extends ConsumerWidget {
  const _Chiffres();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(dashboardProvider).value;
    final cartes = [
      _Chiffre(
        icone: PhosphorIconsLight.signIn,
        valeur: '${r?.arriveesRestantes ?? 0}',
        libelle: 'arrivées à venir',
        detail: 'sur ${r?.arriveesDuJour ?? 0} prévues',
        onTap: () => context.go('/reservations'),
      ),
      _Chiffre(
        icone: PhosphorIconsLight.signOut,
        valeur: '${r?.departsRestants ?? 0}',
        libelle: 'départs à venir',
        detail: 'sur ${r?.departsDuJour ?? 0} prévus',
        onTap: () => context.go('/reservations'),
      ),
      _Chiffre(
        icone: PhosphorIconsLight.broom,
        valeur: '${r?.chambresANettoyer ?? 0}',
        libelle: 'à nettoyer',
        detail: 'chambres sales',
        onTap: () => context.go('/menage'),
      ),
      _Chiffre(
        icone: PhosphorIconsLight.coins,
        valeur: formatAmountShort(r?.caDuJour ?? 0),
        libelle: 'encaissé',
        detail: "chiffre d'affaires du jour",
        onTap: () => context.go('/factures'),
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 14.0;
        final colonnes = c.maxWidth < 360 ? 1 : 2;
        final largeur = (c.maxWidth - gap * (colonnes - 1)) / colonnes;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final carte in cartes) SizedBox(width: largeur, child: carte),
          ],
        );
      },
    );
  }
}

class _Chiffre extends StatelessWidget {
  const _Chiffre({
    required this.icone,
    required this.valeur,
    required this.libelle,
    required this.detail,
    required this.onTap,
  });

  final IconData icone;
  final String valeur;
  final String libelle;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Bezel(
      radius: 24,
      shell: 5,
      padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AtriumColors.mintStrong.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icone, size: 18, color: AtriumColors.mintStrong),
              ),
              const Spacer(),
              Icon(
                PhosphorIconsLight.arrowUpRight,
                size: 15,
                color: AtriumColors.textSecondary,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            valeur,
            maxLines: 1,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 30,
              height: 1,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
              color: AtriumColors.textPrimary,
              fontFeatures: tabularFigures,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            libelle,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AtriumColors.textPrimary,
            ),
          ),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              color: AtriumColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _BlocSejours extends ConsumerWidget {
  const _BlocSejours({
    required this.titre,
    required this.icone,
    required this.vide,
    required this.sejours,
    required this.depart,
  });

  final String titre;
  final IconData icone;
  final String vide;
  final List<ReservationSummary> sejours;
  final bool depart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Bezel(
      padding: const EdgeInsets.fromLTRB(20, 18, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icone, size: 21, color: AtriumColors.mintStrong),
              const SizedBox(width: 10),
              Text(
                titre,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  color: AtriumColors.textPrimary,
                ),
              ),
              const SizedBox(width: 10),
              Tag('${sejours.length}'),
              const Spacer(),
              TextButton(
                onPressed: () => context.go('/reservations'),
                child: const Text('Tout voir'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (sejours.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 18, 0, 22),
              child: Row(
                children: [
                  Icon(
                    PhosphorIconsLight.checkCircle,
                    color: CouleursEtat.disponible,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      vide,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 14.5,
                        color: AtriumColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            for (final (i, s) in sejours.take(6).indexed)
              FadeUp(
                index: i,
                child: _LigneSejour(sejour: s, depart: depart),
              ),
          if (sejours.length > 6)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 6),
              child: Text(
                '+ ${sejours.length - 6} autre(s)',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13,
                  color: AtriumColors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LigneSejour extends ConsumerWidget {
  const _LigneSejour({required this.sejour, required this.depart});

  final ReservationSummary sejour;
  final bool depart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PillButton action;
    if (depart) {
      action = PillButton(
        label: 'Check-out',
        tone: PillTone.quiet,
        compact: true,
        onPressed: () => confirmCheckOut(
          context,
          ref,
          lineId: sejour.lineId,
          guestName: sejour.guestName,
          roomNumber: sejour.roomNumber ?? '',
        ),
      );
    } else if (!sejour.hasRoom) {
      action = PillButton(
        label: 'Attribuer',
        tone: PillTone.quiet,
        compact: true,
        onPressed: () => showAssignRoomDialog(context, sejour),
      );
    } else {
      action = PillButton(
        label: 'Check-in',
        tone: PillTone.accent,
        compact: true,
        onPressed: () => confirmCheckIn(
          context,
          ref,
          lineId: sejour.lineId,
          guestName: sejour.guestName,
          roomNumber: sejour.roomNumber!,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Monogram(sejour.guestName),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sejour.guestName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AtriumColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sejour.hasRoom
                      ? 'Chambre ${sejour.roomNumber}  ·  ${sejour.roomTypeLabel}'
                      : '${sejour.roomTypeLabel}  ·  sans chambre',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13,
                    color: AtriumColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          action,
        ],
      ),
    );
  }
}

/// L'hotel d'un coup d'oeil : un carre par chambre, dans la couleur de son
/// etat, etage par etage. Toucher un carre ouvre la fiche de la chambre.
class _BlocHotel extends ConsumerWidget {
  const _BlocHotel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chambres = ref.watch(roomBoardProvider).value ?? const [];
    final parEtage = <String, List<RoomBoardEntry>>{};
    for (final c in chambres) {
      parEtage.putIfAbsent(c.floorLabel ?? 'Sans étage', () => []).add(c);
    }
    var rang = 0;

    return Bezel(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                PhosphorIconsLight.buildings,
                size: 21,
                color: AtriumColors.mintStrong,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "L'hôtel, chambre par chambre",
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: AtriumColors.textPrimary,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => context.go('/chambres'),
                child: const Text('Ouvrir le plan'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final e in parEtage.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 10),
              child: Text(
                e.key,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AtriumColors.textSecondary,
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in e.value) _CarreChambre(chambre: c, rang: rang++),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CarreChambre extends StatefulWidget {
  const _CarreChambre({required this.chambre, required this.rang});

  final RoomBoardEntry chambre;
  final int rang;

  @override
  State<_CarreChambre> createState() => _CarreChambreState();
}

class _CarreChambreState extends State<_CarreChambre> {
  bool _survol = false;

  @override
  Widget build(BuildContext context) {
    final vue = apparence(widget.chambre.displayStatus);
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 380));
    final carre = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _survol = true),
      onExit: (_) => setState(() => _survol = false),
      child: GestureDetector(
        onTap: () => afficherFicheChambre(context, widget.chambre),
        child: Tooltip(
          message: 'Chambre ${widget.chambre.number} · ${vue.label}',
          child: AnimatedScale(
            scale: _survol ? 1.08 : 1,
            duration: duree,
            curve: atriumSpring,
            child: AnimatedContainer(
              duration: duree,
              curve: atriumSpring,
              width: 64,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: vue.couleur,
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: vue.couleur.withValues(alpha: _survol ? 0.55 : 0.25),
                    blurRadius: _survol ? 20 : 10,
                    spreadRadius: -4,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Text(
                widget.chambre.number,
                style: const TextStyle(
                  fontFamily: atriumFontFamily,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  letterSpacing: -0.3,
                  color: Color(0xFF0A0F2E),
                  fontFeatures: tabularFigures,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return FadeUp(index: widget.rang, child: carre);
  }
}
