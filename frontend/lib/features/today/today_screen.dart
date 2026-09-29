/// Aujourd'hui : l'ecran de travail de la reception.
///
/// Pas un tableau de chiffres a contempler, mais la journee a traiter : qui
/// arrive, qui part, ou en est l'hotel. Chaque ligne porte son action (le
/// check-in, le check-out, l'attribution d'une chambre), pour qu'un agent
/// fasse sa journee sans quitter cet ecran.
///
/// Mise en page en grille « bento » : quatre colonnes sur PC, deux sur
/// tablette, une sur telephone. Toutes les donnees viennent de la base
/// locale, comme partout ailleurs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';
import '../auth/session.dart';
import '../dashboard/dashboard_screen.dart' show dashboardProvider;
import '../reservations/assign_room_dialog.dart';
import '../reservations/stay_actions.dart';
import '../rooms/room_board_screen.dart'
    show apparence, roomBoardProvider;
import '../rooms/room_detail_panel.dart';

/// Les sejours encore attendus ou en cours : de quoi composer les arrivees
/// et les departs du jour.
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

    return Scaffold(
      backgroundColor: AtriumColors.background,
      body: LayoutBuilder(
        builder: (context, c) {
          final colonnes = c.maxWidth >= 1080 ? 4 : (c.maxWidth >= 640 ? 2 : 1);
          final marge = colonnes == 1 ? 16.0 : 28.0;
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(marge, 24, marge, 8),
                sliver: SliverToBoxAdapter(
                  child: _EnTete(
                    prenom: session.agent?.firstName ?? '',
                    jour: jour,
                    peutReserver: session.acces.peut('reservation.create') ||
                        session.acces.peut('rooms.read'),
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(marge, 16, marge, 12),
                sliver: SliverToBoxAdapter(
                  child: _Chiffres(colonnes: colonnes),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(marge, 4, marge, 120),
                sliver: SliverToBoxAdapter(
                  child: _Bento(
                    colonnes: colonnes,
                    arrivees: arrivees,
                    departs: departs,
                  ),
                ),
              ),
            ],
          );
        },
      ),
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
    final texte = Theme.of(context).textTheme;
    final heure = DateTime.now().hour;
    final salut = heure >= 18 || heure < 5 ? 'Bonsoir' : 'Bonjour';
    final titre = prenom.isEmpty ? salut : '$salut, $prenom';

    final bouton = peutReserver
        ? FilledButton.icon(
            onPressed: () => context.go('/reservations/nouvelle'),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Nouvelle réservation'),
          )
        : null;

    return Wrap(
      spacing: 16,
      runSpacing: 16,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatLongDate(jour),
              style: texte.titleSmall?.copyWith(
                color: AtriumColors.mintStrong,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              titre,
              style: texte.displaySmall?.copyWith(fontSize: 34),
            ),
          ],
        ),
        ?bouton,
      ],
    );
  }
}

/// Les cinq chiffres du jour, en une rangee qui se replie.
class _Chiffres extends ConsumerWidget {
  const _Chiffres({required this.colonnes});

  final int colonnes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(dashboardProvider).value;
    final occupees = r?.chambresOccupees ?? 0;
    final total = r?.chambresTotal ?? 0;
    final taux = total == 0 ? 0 : (occupees * 100 / total).round();

    final tuiles = [
      _Chiffre(
        icone: Icons.king_bed_rounded,
        valeur: '$occupees/$total',
        libelle: "Occupation · $taux %",
        progression: total == 0 ? 0 : occupees / total,
        accent: true,
        onTap: () => context.go('/chambres'),
      ),
      _Chiffre(
        icone: Icons.login_rounded,
        valeur: '${r?.arriveesRestantes ?? 0}',
        libelle: 'Arrivées à venir sur ${r?.arriveesDuJour ?? 0}',
        onTap: () => context.go('/reservations'),
      ),
      _Chiffre(
        icone: Icons.logout_rounded,
        valeur: '${r?.departsRestants ?? 0}',
        libelle: 'Départs à venir sur ${r?.departsDuJour ?? 0}',
        onTap: () => context.go('/reservations'),
      ),
      _Chiffre(
        icone: Icons.cleaning_services_rounded,
        valeur: '${r?.chambresANettoyer ?? 0}',
        libelle: 'Chambres à nettoyer',
        onTap: () => context.go('/menage'),
      ),
      _Chiffre(
        icone: Icons.payments_rounded,
        valeur: formatAmountShort(r?.caDuJour ?? 0),
        libelle: "Chiffre d'affaires du jour",
        onTap: () => context.go('/factures'),
      ),
    ];

    // Telephone : un defilement horizontal plutot qu'une colonne de cinq
    // cartes, qui repousserait les arrivees sous la ligne de flottaison.
    if (colonnes == 1) {
      return SizedBox(
        height: 132,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: tuiles.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, i) => SizedBox(width: 176, child: tuiles[i]),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        // Autant de tuiles par rangee que la largeur en tient, jamais une
        // rangee a trous.
        final parLigne = (c.maxWidth / 170).floor().clamp(2, 5);
        final largeur = (c.maxWidth - 12 * (parLigne - 1)) / parLigne;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final t in tuiles) SizedBox(width: largeur, height: 132, child: t),
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
    this.progression,
    this.accent = false,
    this.onTap,
  });

  final IconData icone;
  final String valeur;
  final String libelle;
  final double? progression;
  final bool accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    // La premiere tuile porte la couleur de nuit : un seul point fort par
    // rangee, sinon plus rien ne ressort.
    final fond = accent ? AtriumColors.purpleNight : AtriumColors.white;
    final encre = accent ? AtriumColors.onNight : AtriumColors.textPrimary;
    final doux = accent ? AtriumColors.onPurpleSoft : AtriumColors.textSecondary;

    return _Surface(
      couleur: fond,
      bordure: !accent,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icone, size: 22, color: AtriumColors.mintStrong),
            const Spacer(),
            Text(
              valeur,
              maxLines: 1,
              style: texte.headlineMedium?.copyWith(
                color: encre,
                fontWeight: FontWeight.w800,
                fontFeatures: tabularFigures,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              libelle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: texte.bodySmall?.copyWith(color: doux),
            ),
            if (progression != null) ...[
              const SizedBox(height: 8),
              _Jauge(valeur: progression!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Une jauge qui se remplit a l'ouverture.
class _Jauge extends StatelessWidget {
  const _Jauge({required this.valeur});

  final double valeur;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: 6,
        child: Stack(
          children: [
            Container(color: AtriumColors.onNight.withValues(alpha: 0.12)),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: valeur.clamp(0, 1)),
              duration: AtriumMotion.of(
                context,
                const Duration(milliseconds: 900),
              ),
              curve: Curves.easeOutExpo,
              builder: (_, v, _) => FractionallySizedBox(
                widthFactor: v,
                child: Container(color: AtriumColors.mintStrong),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Les grands blocs du jour.
class _Bento extends StatelessWidget {
  const _Bento({
    required this.colonnes,
    required this.arrivees,
    required this.departs,
  });

  final int colonnes;
  final List<ReservationSummary> arrivees;
  final List<ReservationSummary> departs;

  @override
  Widget build(BuildContext context) {
    final blocArrivees = _BlocSejours(
      titre: 'Arrivées',
      icone: Icons.login_rounded,
      vide: "Plus d'arrivée attendue aujourd'hui.",
      sejours: arrivees,
      depart: false,
    );
    final blocDeparts = _BlocSejours(
      titre: 'Départs',
      icone: Icons.logout_rounded,
      vide: "Plus de départ attendu aujourd'hui.",
      sejours: departs,
      depart: true,
    );
    const hotel = _BlocHotel();

    if (colonnes == 1) {
      return Column(
        children: [
          blocArrivees,
          const SizedBox(height: 12),
          blocDeparts,
          const SizedBox(height: 12),
          hotel,
        ],
      );
    }
    if (colonnes == 2) {
      return Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: blocArrivees),
              const SizedBox(width: 12),
              Expanded(child: blocDeparts),
            ],
          ),
          const SizedBox(height: 12),
          hotel,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Column(
            children: [
              blocArrivees,
              const SizedBox(height: 12),
              blocDeparts,
            ],
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(flex: 2, child: hotel),
      ],
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
    final texte = Theme.of(context).textTheme;
    return _Surface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icone, size: 22, color: AtriumColors.mintStrong),
                const SizedBox(width: 10),
                Text(titre, style: texte.titleLarge),
                const SizedBox(width: 8),
                _Compteur(sejours.length),
                const Spacer(),
                TextButton(
                  onPressed: () => context.go('/reservations'),
                  child: const Text('Tout voir'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (sejours.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 22),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      color: CouleursEtat.disponible,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(vide, style: texte.bodyMedium)),
                  ],
                ),
              )
            else
              for (final (i, s) in sejours.take(6).indexed) ...[
                if (i > 0) Divider(color: AtriumColors.border),
                _LigneSejour(sejour: s, depart: depart),
              ],
            if (sejours.length > 6)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text(
                  '+ ${sejours.length - 6} autre(s)',
                  style: texte.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Compteur extends StatelessWidget {
  const _Compteur(this.n);

  final int n;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
        color: AtriumColors.mintSoft,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        '$n',
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontWeight: FontWeight.w800,
          fontSize: 13,
          color: AtriumColors.textPrimary,
          fontFeatures: tabularFigures,
        ),
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
    final texte = Theme.of(context).textTheme;
    final initiales = sejour.guestName
        .split(' ')
        .where((m) => m.isNotEmpty)
        .take(2)
        .map((m) => m.characters.first.toUpperCase())
        .join();

    Widget action;
    if (depart) {
      action = OutlinedButton(
        onPressed: () => confirmCheckOut(
          context,
          ref,
          lineId: sejour.lineId,
          guestName: sejour.guestName,
          roomNumber: sejour.roomNumber ?? '',
        ),
        style: _petitBouton,
        child: const Text('Check-out'),
      );
    } else if (!sejour.hasRoom) {
      action = OutlinedButton(
        onPressed: () => showAssignRoomDialog(context, sejour),
        style: _petitBouton,
        child: const Text('Attribuer'),
      );
    } else {
      action = FilledButton(
        onPressed: () => confirmCheckIn(
          context,
          ref,
          lineId: sejour.lineId,
          guestName: sejour.guestName,
          roomNumber: sejour.roomNumber!,
        ),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        child: const Text('Check-in'),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 21,
            backgroundColor: AtriumColors.mintSoft,
            child: Text(
              initiales,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: AtriumColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sejour.guestName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: texte.titleSmall,
                ),
                Text(
                  sejour.hasRoom
                      ? 'Ch. ${sejour.roomNumber}  ·  ${sejour.roomTypeLabel}'
                      : '${sejour.roomTypeLabel}  ·  sans chambre',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: texte.bodySmall,
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

final _petitBouton = OutlinedButton.styleFrom(
  minimumSize: const Size(0, 42),
  padding: const EdgeInsets.symmetric(horizontal: 14),
);

/// L'hotel d'un coup d'oeil : un carre par chambre, dans la couleur de son
/// etat, etage par etage. Toucher un carre ouvre la fiche de la chambre.
class _BlocHotel extends ConsumerWidget {
  const _BlocHotel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final texte = Theme.of(context).textTheme;
    final chambres = ref.watch(roomBoardProvider).value ?? const [];
    final parEtage = <String, List<RoomBoardEntry>>{};
    for (final c in chambres) {
      parEtage.putIfAbsent(c.floorLabel ?? 'Sans étage', () => []).add(c);
    }

    return _Surface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.apartment_rounded,
                  size: 22,
                  color: AtriumColors.mintStrong,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text("L'hôtel", style: texte.titleLarge)),
                TextButton(
                  onPressed: () => context.go('/chambres'),
                  child: const Text('Plan'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final e in parEtage.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Text(e.key, style: texte.labelSmall),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, c) in e.value.indexed)
                    _CarreChambre(chambre: c, rang: i),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final etat in RoomDisplayStatus.values)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: apparence(etat).couleur,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(apparence(etat).label, style: texte.bodySmall),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CarreChambre extends StatelessWidget {
  const _CarreChambre({required this.chambre, required this.rang});

  final RoomBoardEntry chambre;
  final int rang;

  @override
  Widget build(BuildContext context) {
    final couleur = apparence(chambre.displayStatus).couleur;
    final carre = Tooltip(
      message:
          'Chambre ${chambre.number} · ${apparence(chambre.displayStatus).label}',
      child: Material(
        color: couleur,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => afficherFicheChambre(context, chambre),
          child: SizedBox(
            width: 58,
            height: 46,
            child: Center(
              child: Text(
                chambre.number,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: const Color(0xFF0A0F2E),
                  fontFeatures: tabularFigures,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (MediaQuery.disableAnimationsOf(context)) return carre;
    final delai = (rang * 40).clamp(0, 400);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + delai),
      curve: Interval(delai / (420 + delai), 1, curve: Curves.easeOutBack),
      builder: (_, t, enfant) =>
          Transform.scale(scale: 0.6 + 0.4 * t, child: Opacity(opacity: t.clamp(0, 1), child: enfant)),
      child: carre,
    );
  }
}

/// Une carte du bento : papier, bord fin, rayon genereux.
class _Surface extends StatelessWidget {
  const _Surface({
    required this.child,
    this.couleur,
    this.bordure = true,
    this.onTap,
  });

  final Widget child;
  final Color? couleur;
  final bool bordure;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final rayon = BorderRadius.circular(22);
    return Material(
      color: couleur ?? AtriumColors.white,
      borderRadius: rayon,
      child: InkWell(
        borderRadius: rayon,
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: rayon,
            border: bordure ? Border.all(color: AtriumColors.border) : null,
          ),
          child: child,
        ),
      ),
    );
  }
}
