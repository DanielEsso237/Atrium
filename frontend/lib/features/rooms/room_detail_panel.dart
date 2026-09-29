/// La fiche qui s'ouvre au clic sur une chambre (paragraphe 5.2).
///
/// Le cahier des charges impose son contenu : numero, type, prix, client
/// actuel, dates, consommations, etat, historique, et les trois boutons
/// Check-in / Check-out / Ajouter consommation.
///
/// Les trois boutons sont inertes pour l'instant : ce sont des ecritures, et
/// une ecriture locale qui ne remonterait jamais au serveur serait pire que
/// pas de bouton du tout. Ils s'activeront avec la couche de liaison.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/enums.dart';
import '../auth/session.dart';
import '../billing/charge_labels.dart';
import '../maintenance/maintenance_screen.dart' show showReportIssueDialog;
import '../../data/local/database_provider.dart';
import '../../data/local/queries/room_detail_queries.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../billing/add_charge_dialog.dart';
import '../reservations/stay_actions.dart';
import 'room_board_screen.dart';

final ficheChambreProvider = StreamProvider.family<RoomDetail, String>((
  ref,
  roomId,
) {
  return ref.watch(databaseProvider).watchRoomDetail(roomId);
});

/// Ouvre la fiche en panneau lateral.
///
/// Un panneau plutot qu'une page : la reception garde le plan sous les yeux et
/// ferme d'un geste, ce qui compte quand on enchaine dix chambres. Sur
/// tablette et PC il glisse depuis la droite ; sur telephone il monte du bas.
void afficherFicheChambre(BuildContext context, RoomBoardEntry chambre) {
  final large = MediaQuery.sizeOf(context).width >= 900;
  if (!large) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.92,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          child: _Fiche(chambre: chambre),
        ),
      ),
    );
    return;
  }
  final p = AtriumPalette.current;
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fermer la fiche',
    barrierColor: p.night.withValues(alpha: p.isDark ? 0.6 : 0.35),
    transitionDuration: AtriumMotion.of(
      context,
      const Duration(milliseconds: 520),
    ),
    pageBuilder: (_, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: SizedBox(
          width: 500,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: _Fiche(chambre: chambre),
          ),
        ),
      ),
    ),
    transitionBuilder: (_, animation, _, enfant) {
      final t = CurvedAnimation(parent: animation, curve: atriumSpring);
      return SlideTransition(
        position: Tween(
          begin: const Offset(0.35, 0),
          end: Offset.zero,
        ).animate(t),
        child: FadeTransition(opacity: t, child: enfant),
      );
    },
  );
}

class _Fiche extends ConsumerWidget {
  const _Fiche({required this.chambre});

  final RoomBoardEntry chambre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fiche = ref.watch(ficheChambreProvider(chambre.roomId));
    final vue = apparence(chambre.displayStatus);
    final p = AtriumPalette.current;

    return Material(
      color: p.background,
      child: Column(
        children: [
          _Entete(chambre: chambre, vue: vue),
          Expanded(
            child: fiche.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(
                icon: PhosphorIconsLight.warningCircle,
                title: 'Lecture impossible',
                message: '$e',
              ),
              data: (f) => ListView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
                children: [
                  FadeUp(child: _Axes(chambre: chambre)),
                  const SizedBox(height: 14),
                  if (f.sejour != null) ...[
                    FadeUp(
                      index: 1,
                      child: _Sejour(
                        titre: 'Séjour en cours',
                        sejour: f.sejour!,
                      ),
                    ),
                    const SizedBox(height: 14),
                    FadeUp(
                      index: 2,
                      child: _Consommations(lignes: f.consommations),
                    ),
                  ] else if (f.expected != null)
                    FadeUp(
                      index: 1,
                      child: _Sejour(
                        titre: 'Arrivée attendue',
                        sejour: f.expected!,
                      ),
                    )
                  else
                    FadeUp(
                      index: 1,
                      child: _Bloc(
                        titre: 'Séjour en cours',
                        enfant: _Vide("Aucun client dans cette chambre."),
                      ),
                    ),
                  const SizedBox(height: 14),
                  FadeUp(index: 3, child: _Historique(sejours: f.historique)),
                ],
              ),
            ),
          ),
          _Actions(fiche: fiche.value, chambre: chambre),
        ],
      ),
    );
  }
}

/// L'en-tete : le numero en tres grand sur la nuit, l'etat en couleur.
class _Entete extends ConsumerWidget {
  const _Entete({required this.chambre, required this.vue});

  final RoomBoardEntry chambre;
  final ({String label, Color couleur}) vue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peutSignaler = ref
        .watch(sessionProvider)
        .acces
        .peut('maintenance.manage');
    final p = AtriumPalette.current;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 14, 22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              vue.couleur.withValues(alpha: p.isDark ? 0.28 : 0.2),
              p.isDark ? p.night : p.paper,
            ),
            p.isDark ? p.night : p.paper,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: vue.couleur.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: vue.couleur.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: vue.couleur,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      vue.label,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: p.onHero,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              // Signaler un probleme la ou on le decouvre : un client
              // appelle, la reception a la fiche sous les yeux.
              if (peutSignaler)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    tooltip: 'Signaler un problème',
                    style: IconButton.styleFrom(
                      backgroundColor: p.onHero.withValues(alpha: 0.1),
                    ),
                    icon: Icon(
                      PhosphorIconsLight.wrench,
                      color: p.onHero,
                      size: 22,
                    ),
                    onPressed: () => showReportIssueDialog(
                      context,
                      roomId: chambre.roomId,
                      roomNumber: chambre.number,
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Fermer',
                style: IconButton.styleFrom(
                  backgroundColor: p.onHero.withValues(alpha: 0.1),
                ),
                icon: Icon(PhosphorIconsLight.x, color: p.onHero, size: 22),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            chambre.number,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 64,
              fontWeight: FontWeight.w800,
              letterSpacing: -3,
              height: 1,
              color: p.onHero,
              fontFeatures: tabularFigures,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            [
              chambre.typeLabel,
              chambre.floorLabel ?? 'Sans étage',
              '${formatAmount(chambre.rate)} / nuit',
            ].join('  ·  '),
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: p.onHeroSoft,
            ),
          ),
        ],
      ),
    );
  }
}

/// Les trois axes, cote a cote et non fondus en un seul mot : c'est ce qui
/// permet a la reception et au housekeeping de lire la meme fiche sans se
/// contredire.
class _Axes extends StatelessWidget {
  const _Axes({required this.chambre});

  final RoomBoardEntry chambre;

  @override
  Widget build(BuildContext context) {
    final occupation = switch (chambre.occupancy) {
      OccupancyStatus.VACANT => (PhosphorIconsLight.doorOpen, 'Libre'),
      OccupancyStatus.RESERVED => (
        PhosphorIconsLight.calendarCheck,
        'Réservée',
      ),
      OccupancyStatus.OCCUPIED => (PhosphorIconsLight.user, 'Occupée'),
    };
    final proprete = switch (chambre.housekeeping) {
      HousekeepingStatus.CLEAN => (PhosphorIconsLight.sparkle, 'Propre'),
      HousekeepingStatus.DIRTY => (PhosphorIconsLight.broom, 'Sale'),
      HousekeepingStatus.IN_PROGRESS => (PhosphorIconsLight.broom, 'En cours'),
      HousekeepingStatus.INSPECTED => (
        PhosphorIconsLight.sealCheck,
        'Inspectée',
      ),
    };
    final service = chambre.isOutOfOrder
        ? (PhosphorIconsLight.wrench, 'Hors service')
        : (PhosphorIconsLight.checkCircle, 'En service');
    return Row(
      children: [
        Expanded(child: _Axe('Occupation', occupation.$1, occupation.$2)),
        const SizedBox(width: 10),
        Expanded(child: _Axe('Propreté', proprete.$1, proprete.$2)),
        const SizedBox(width: 10),
        Expanded(child: _Axe('Service', service.$1, service.$2)),
      ],
    );
  }
}

class _Axe extends StatelessWidget {
  const _Axe(this.titre, this.icone, this.valeur);

  final String titre;
  final IconData icone;
  final String valeur;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.paper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 22, color: p.accent),
          const SizedBox(height: 10),
          Text(
            valeur,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: p.text,
            ),
          ),
          Text(
            titre,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12,
              color: p.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Sejour extends StatelessWidget {
  const _Sejour({required this.titre, required this.sejour});

  final String titre;
  final CurrentStay sejour;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final arrivee = parseIsoDate(sejour.arrival);
    final depart = parseIsoDate(sejour.departure);
    final nuits = (arrivee != null && depart != null)
        ? depart.difference(arrivee).inDays
        : 0;

    Widget date(String libelle, DateTime? d, String brut) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(libelle, style: _styleCle),
          const SizedBox(height: 2),
          Text(
            d == null ? brut : formatDayMonth(d),
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: p.text,
            ),
          ),
        ],
      ),
    );

    return _Bloc(
      titre: titre,
      enfant: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Monogram(sejour.guestName, size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sejour.guestName,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: p.text,
                      ),
                    ),
                    Text(
                      '${sejour.adultes} adulte${sejour.adultes > 1 ? 's' : ''}'
                      '${sejour.enfants > 0 ? ', ${sejour.enfants} enfant${sejour.enfants > 1 ? 's' : ''}' : ''}'
                      '  ·  ${formatAmount(sejour.nightlyRate)} / nuit',
                      style: _styleCle,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.surfaceMuted.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                date('Arrivée', arrivee, sejour.arrival),
                Column(
                  children: [
                    Icon(
                      PhosphorIconsLight.moonStars,
                      size: 18,
                      color: p.accent,
                    ),
                    Text(
                      '$nuits nuit${nuits > 1 ? 's' : ''}',
                      style: _styleCle.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(width: 18),
                date('Départ', depart, sejour.departure),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text("Solde de l'ardoise", style: _styleCle),
              const Spacer(),
              Text(
                formatAmount(sejour.balance),
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                  color: sejour.balance > 0 ? p.accent : p.text,
                  fontFeatures: tabularFigures,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Consommations extends StatelessWidget {
  const _Consommations({required this.lignes});

  final List<Charge> lignes;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return _Bloc(
      titre: 'Consommations',
      compteur: lignes.length,
      enfant: lignes.isEmpty
          ? _Vide("Rien n'est encore porté à l'ardoise.")
          : Column(
              children: [
                for (final l in lignes)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: p.surfaceMuted,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            chargeCategoryIcon(l.categorie),
                            size: 18,
                            color: p.text,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.libelle, style: _styleValeur),
                              Text(
                                '${chargeCategoryLabel(l.categorie)} · ${_jour(l.journee)}',
                                style: _styleCle,
                              ),
                            ],
                          ),
                        ),
                        Text(
                          formatAmount(l.montant),
                          style: _styleValeur.copyWith(
                            fontWeight: FontWeight.w800,
                            fontFeatures: tabularFigures,
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

String _jour(String iso) {
  final d = parseIsoDate(iso);
  return d == null ? iso : formatDayMonth(d);
}

class _Historique extends StatelessWidget {
  const _Historique({required this.sejours});

  final List<PastStay> sejours;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return _Bloc(
      titre: 'Historique',
      compteur: sejours.length,
      enfant: sejours.isEmpty
          ? _Vide('Aucun séjour terminé dans cette chambre.')
          : Column(
              children: [
                for (var i = 0; i < sejours.length; i++)
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Une frise : un point par sejour, relies.
                        SizedBox(
                          width: 20,
                          child: Column(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                margin: const EdgeInsets.only(top: 6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: p.accent, width: 2),
                                ),
                              ),
                              if (i < sejours.length - 1)
                                Expanded(
                                  child: Container(width: 2, color: p.border),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(sejours[i].guestName, style: _styleValeur),
                                Text(
                                  '${_jour(sejours[i].arrival)} → ${_jour(sejours[i].departure)}',
                                  style: _styleCle,
                                ),
                              ],
                            ),
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

class _Actions extends ConsumerWidget {
  const _Actions({required this.fiche, required this.chambre});

  final RoomDetail? fiche;
  final RoomBoardEntry chambre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final sejour = fiche?.sejour;
    final attendu = fiche?.expected;

    // Le check-in n'a de sens que si un sejour attribue attend, et le
    // check-out que si quelqu'un est la. Les deux ne sont jamais proposes
    // ensemble : ce serait offrir une action impossible.
    final boutons = <Widget>[
      if (attendu != null)
        PillButton(
          label: 'Check-in',
          icon: PhosphorIconsLight.signIn,
          tone: PillTone.accent,
          expand: true,
          onPressed: () async {
            final fait = await confirmCheckIn(
              context,
              ref,
              lineId: attendu.lineId,
              guestName: attendu.guestName,
              roomNumber: chambre.number,
            );
            if (fait && context.mounted) Navigator.of(context).pop();
          },
        ),
      if (sejour != null)
        PillButton(
          label: 'Check-out',
          icon: PhosphorIconsLight.signOut,
          tone: PillTone.primary,
          expand: true,
          onPressed: () async {
            final fait = await confirmCheckOut(
              context,
              ref,
              lineId: sejour.lineId,
              guestName: sejour.guestName,
              roomNumber: chambre.number,
            );
            if (fait && context.mounted) Navigator.of(context).pop();
          },
        ),
      // Une consommation ne se porte que sur une ardoise ouverte, donc
      // uniquement pendant un sejour en cours.
      if (sejour != null && sejour.folioId != null)
        PillButton(
          label: 'Consommation',
          icon: PhosphorIconsLight.plus,
          tone: PillTone.quiet,
          expand: true,
          onPressed: () => showAddChargeDialog(
            context,
            folioId: sejour.folioId!,
            guestName: sejour.guestName,
          ),
        ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      decoration: BoxDecoration(
        color: p.paper,
        border: Border(top: BorderSide(color: p.border)),
      ),
      child: SafeArea(
        top: false,
        child: boutons.isEmpty
            ? Text(
                fiche == null
                    ? ' '
                    : 'Aucune action : personne n’est attendu ni présent.',
                textAlign: TextAlign.center,
                style: _styleCle,
              )
            : Row(
                children: [
                  for (var i = 0; i < boutons.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(child: boutons[i]),
                  ],
                ],
              ),
      ),
    );
  }
}

TextStyle get _styleCle => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 13,
  fontWeight: FontWeight.w500,
  color: AtriumColors.textSecondary,
  fontFeatures: tabularFigures,
);

TextStyle get _styleValeur => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 15,
  fontWeight: FontWeight.w600,
  color: AtriumColors.textPrimary,
);

class _Vide extends StatelessWidget {
  const _Vide(this.texte);

  final String texte;

  @override
  Widget build(BuildContext context) =>
      Text(texte, style: _styleCle.copyWith(fontSize: 14));
}

class _Bloc extends StatelessWidget {
  const _Bloc({required this.titre, required this.enfant, this.compteur});

  final String titre;
  final Widget enfant;
  final int? compteur;

  @override
  Widget build(BuildContext context) {
    return Bezel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(
            titre,
            trailing: compteur == null
                ? null
                : Text(
                    '$compteur',
                    style: _styleCle.copyWith(fontWeight: FontWeight.w800),
                  ),
          ),
          const SizedBox(height: 14),
          enfant,
        ],
      ),
    );
  }
}
