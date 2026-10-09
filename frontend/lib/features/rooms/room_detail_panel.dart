/// La fiche qui s'ouvre au clic sur une chambre (paragraphe 5.2).
///
/// Le cahier des charges impose son contenu : numero, type, prix, client
/// actuel, dates, consommations, etat, historique, et les trois gestes
/// Check-in / Check-out / Ajouter consommation.
///
/// Seuls les gestes possibles sont proposes : le check-in quand un client
/// attendu a cette chambre, le depart et les consommations quand quelqu'un
/// y dort. Un bouton grise n'apprend rien a la reception, il lui fait
/// essayer une porte fermee.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/prolongation.dart';
import '../../core/tokens.dart';
import '../../core/widgets/atrium_bandeau.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/room_detail_queries.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../../data/repositories/repository_providers.dart' show stayRulesProvider;
import '../billing/add_charge_dialog.dart';
import '../auth/session.dart';
import '../billing/charge_labels.dart';
import '../maintenance/maintenance_screen.dart' show showReportIssueDialog;
import '../reservations/stay_actions.dart';
import 'room_board_screen.dart';

final ficheChambreProvider = StreamProvider.family<RoomDetail, String>((
  ref,
  roomId,
) {
  return ref.watch(databaseProvider).watchRoomDetail(roomId);
});

/// Ouvre la fiche : en panneau lateral sur une tablette couchee, pour garder
/// le plan sous les yeux et enchainer dix chambres ; en feuille qui monte du
/// bas sur un telephone, ou la place manque pour les deux.
void afficherFicheChambre(BuildContext context, RoomBoardEntry chambre) {
  final theme = Theme.of(context);
  final large = MediaQuery.sizeOf(context).width >= 900;

  if (large) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Fermer la fiche',
      barrierColor: AtriumDashColors.title.withValues(alpha: 0.35),
      transitionDuration: AtriumMotion.of(
        context,
        const Duration(milliseconds: 320),
      ),
      pageBuilder: (_, _, _) => Theme(
        data: theme,
        child: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 500,
            height: double.infinity,
            child: _Fiche(chambre: chambre, panneau: true),
          ),
        ),
      ),
      transitionBuilder: (_, animation, _, enfant) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: enfant,
      ),
    );
    return;
  }

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Theme(
      data: theme,
      child: FractionallySizedBox(
        heightFactor: 0.94,
        child: _Fiche(chambre: chambre, panneau: false),
      ),
    ),
  );
}

class _Fiche extends ConsumerWidget {
  const _Fiche({required this.chambre, required this.panneau});

  /// La chambre telle qu'au clic ; la fiche suit ensuite le plan en direct.
  final RoomBoardEntry chambre;
  final bool panneau;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fiche = ref.watch(ficheChambreProvider(chambre.roomId));
    final actuelle =
        ref
            .watch(roomBoardProvider)
            .value
            ?.where((c) => c.roomId == chambre.roomId)
            .firstOrNull ??
        chambre;
    final vue = apparence(actuelle.displayStatus);

    return Material(
      color: AtriumDashColors.page,
      clipBehavior: Clip.antiAlias,
      borderRadius: panneau
          ? const BorderRadius.horizontal(left: Radius.circular(28))
          : const BorderRadius.vertical(top: Radius.circular(28)),
      child: Column(
        children: [
          _EnTete(chambre: actuelle, vue: vue, panneau: panneau),
          Expanded(
            child: fiche.when(
              loading: () => Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AtriumColors.mintStrong,
                ),
              ),
              error: (e, _) => Center(child: Text('Lecture impossible : $e')),
              data: (f) => ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                children: [
                  if (f.sejour != null) ...[
                    _Sejour(
                      sejour: f.sejour!,
                      titre: 'Séjour en cours',
                      afficherDepart: true,
                    ),
                    const SizedBox(height: 16),
                    _Consommations(lignes: f.consommations),
                  ] else if (f.expected != null)
                    _Sejour(sejour: f.expected!, titre: 'Arrivée attendue')
                  else
                    _Carte(
                      child: Row(
                        children: [
                          _Tuile(
                            icone: vue.icone,
                            fond: vue.fond,
                            encre: vue.encre,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              'Aucun client dans cette chambre.',
                              style: TextStyle(
                                fontSize: 15.5,
                                color: AtriumColors.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  _Caracteristiques(chambre: actuelle),
                  const SizedBox(height: 16),
                  _Historique(sejours: f.historique),
                ],
              ),
            ),
          ),
          _Actions(fiche: fiche.value, chambre: actuelle),
        ],
      ),
    );
  }
}

// --- En-tete -----------------------------------------------------------------

/// La chambre de nuit en fond, le numero comme sur la plaque de la porte.
class _EnTete extends ConsumerWidget {
  const _EnTete({
    required this.chambre,
    required this.vue,
    required this.panneau,
  });

  final RoomBoardEntry chambre;
  final ApparenceEtat vue;
  final bool panneau;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peutSignaler = ref
        .watch(sessionProvider)
        .acces
        .peut('maintenance.manage');
    final haut = panneau ? MediaQuery.paddingOf(context).top : 0.0;
    final lieu = [
      chambre.typeLabel,
      if (chambre.floorLabel != null) chambre.floorLabel!.toLowerCase(),
    ].join(', ');

    return SizedBox(
      height: 200 + haut,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            photoChambre,
            fit: BoxFit.cover,
            alignment: const Alignment(0.4, 0.2),
            color: AtriumColors.photoTint,
            colorBlendMode: BlendMode.multiply,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
          ),
          // La nuit monte du bas : le numero et le prix se lisent en blanc
          // sans ombre portee.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AtriumColors.purpleNight.withValues(alpha: 0.35),
                  AtriumColors.purpleNight.withValues(alpha: 0.6),
                  AtriumColors.purpleNight.withValues(alpha: 0.94),
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(22, haut + 14, 14, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!panneau)
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: AtriumColors.white.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    PastilleEtat(apparence: vue, surFonce: true),
                    const Spacer(),
                    // Signaler un probleme la ou on le decouvre : un client
                    // appelle, la reception a la fiche sous les yeux.
                    if (peutSignaler)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Material(
                          color: AtriumColors.white.withValues(alpha: 0.16),
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => showReportIssueDialog(
                              context,
                              roomId: chambre.roomId,
                              roomNumber: chambre.number,
                            ),
                            child: Tooltip(
                              message: 'Signaler un problème',
                              child: SizedBox.square(
                                dimension: 44,
                                child: Icon(
                                  Icons.build_outlined,
                                  color: AtriumColors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Semantics(
                      button: true,
                      label: 'Fermer la fiche',
                      excludeSemantics: true,
                      child: Material(
                        color: AtriumColors.white.withValues(alpha: 0.16),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.of(context).pop(),
                          child: SizedBox.square(
                            dimension: 44,
                            child: Icon(
                              Icons.close_rounded,
                              color: AtriumColors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Chambre ${chambre.number}',
                            style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                              color: AtriumColors.white,
                              height: 1.1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            lieu,
                            style: TextStyle(
                              fontSize: 15,
                              color: AtriumColors.onPurpleSoft,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatAmount(chambre.rate),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AtriumColors.white,
                          ),
                        ),
                        Text(
                          'la nuit',
                          style: TextStyle(
                            fontSize: 13,
                            color: AtriumColors.onPurpleSoft,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Sections ----------------------------------------------------------------

class _Carte extends StatelessWidget {
  const _Carte({required this.child, this.titre});

  final String? titre;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AtriumDashColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AtriumDashColors.cardBorder),
        boxShadow: AtriumShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (titre != null) ...[
            Text(
              titre!,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AtriumDashColors.title,
              ),
            ),
            const SizedBox(height: 14),
          ],
          child,
        ],
      ),
    );
  }
}

class _Tuile extends StatelessWidget {
  const _Tuile({
    required this.icone,
    required this.fond,
    required this.encre,
    this.taille = 42,
  });

  final IconData icone;
  final Color fond;
  final Color encre;
  final double taille;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(taille * 0.3),
      ),
      alignment: Alignment.center,
      child: Icon(icone, size: taille * 0.5, color: encre),
    );
  }
}

class _Sejour extends ConsumerWidget {
  const _Sejour({
    required this.sejour,
    required this.titre,
    this.afficherDepart = false,
  });

  final CurrentStay sejour;
  final String titre;

  /// Seulement pour un client present : l'heure de depart n'a pas de sens
  /// avant son arrivee.
  final bool afficherDepart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regles = ref.watch(stayRulesProvider).value;
    final arrivee = parseIsoDate(sejour.arrival);
    final depart = parseIsoDate(sejour.departure);
    final aujourdhui = businessDayFor(DateTime.now());
    final nuits = arrivee == null || depart == null
        ? null
        : depart.difference(arrivee).inDays;
    final nuitEnCours = arrivee == null
        ? null
        : aujourdhui.difference(arrivee).inDays + 1;
    final personnes = [
      '${sejour.adultes} adulte${sejour.adultes > 1 ? 's' : ''}',
      if (sejour.enfants > 0)
        '${sejour.enfants} enfant${sejour.enfants > 1 ? 's' : ''}',
    ].join(', ');

    return _Carte(
      titre: titre,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AtriumColors.purpleBright, AtriumColors.purple],
                  ),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  _initiales(sejour.guestName),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AtriumColors.white,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sejour.guestName,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AtriumDashColors.title,
                      ),
                    ),
                    Text(
                      personnes,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: AtriumColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _Date(
                  libelle: 'Arrivée',
                  date: arrivee,
                  brut: sejour.arrival,
                ),
              ),
              Icon(
                Icons.east_rounded,
                size: 20,
                color: AtriumColors.textSecondary,
              ),
              Expanded(
                child: _Date(
                  libelle: 'Départ',
                  date: depart,
                  brut: sejour.departure,
                  alignerFin: true,
                ),
              ),
            ],
          ),
          if (nuits != null && nuits > 0 && nuitEnCours != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (nuitEnCours / nuits).clamp(0.0, 1.0),
                      minHeight: 6,
                      color: AtriumColors.purple,
                      backgroundColor: AtriumDashColors.control,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  nuitEnCours <= 0
                      ? '$nuits nuit${nuits > 1 ? 's' : ''}'
                      : 'Nuit ${nuitEnCours.clamp(1, nuits)} sur $nuits',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AtriumColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          _Ligne(
            cle: 'Tarif de la nuit',
            valeur: formatAmount(sejour.nightlyRate),
          ),
          if (afficherDepart && depart != null)
            _Ligne(
              cle: 'Heure de départ',
              valeur: _heureDeDepart(
                depart,
                regles?.checkoutHour ?? heureDepartParDefaut,
                sejour.prolongationHeures,
              ),
            ),
          const SizedBox(height: 12),
          _Solde(solde: sejour.balance),
        ],
      ),
    );
  }
}

/// « 12 h », ou « 15 h (prolongé de 3 h) » quand une prolongation est portee.
String _heureDeDepart(DateTime depart, int heureDepart, int prolongation) {
  final limite = limiteDeDepart(
    depart,
    heureDepart: heureDepart,
    heuresProlongees: prolongation,
  );
  return prolongation > 0
      ? '${formatHeure(limite)} (prolongé de $prolongation h)'
      : formatHeure(limite);
}

class _Date extends StatelessWidget {
  const _Date({
    required this.libelle,
    required this.date,
    required this.brut,
    this.alignerFin = false,
  });

  final String libelle;
  final DateTime? date;
  final String brut;
  final bool alignerFin;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignerFin
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          libelle,
          style: TextStyle(fontSize: 12.5, color: AtriumColors.textSecondary),
        ),
        const SizedBox(height: 2),
        Text(
          date == null ? brut : formatShortDate(date!),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AtriumDashColors.title,
            fontFeatures: tabularFigures,
          ),
        ),
      ],
    );
  }
}

/// Le solde de l'ardoise, en evidence : c'est la question du client qui part.
class _Solde extends StatelessWidget {
  const _Solde({required this.solde});

  final int solde;

  @override
  Widget build(BuildContext context) {
    final (libelle, fond, encre) = solde > 0
        ? (
            'Reste à régler',
            AtriumRoomColors.reservedTint,
            AtriumRoomColors.reservedInk,
          )
        : (
            'Ardoise soldée',
            AtriumRoomColors.availableTint,
            AtriumRoomColors.availableInk,
          );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(AtriumRadii.md),
      ),
      child: Row(
        children: [
          Icon(
            solde > 0
                ? Icons.account_balance_wallet_outlined
                : Icons.verified_outlined,
            color: encre,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              libelle,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: encre,
              ),
            ),
          ),
          Text(
            formatAmount(solde),
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: encre,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}

IconData _iconeCategorie(ChargeCategory c) => switch (c) {
  ChargeCategory.ROOM => Icons.bed_outlined,
  ChargeCategory.FNB => Icons.restaurant_outlined,
  ChargeCategory.MINIBAR => Icons.local_bar_outlined,
  ChargeCategory.SPA => Icons.spa_outlined,
  ChargeCategory.LAUNDRY => Icons.local_laundry_service_outlined,
  ChargeCategory.TELEPHONE => Icons.phone_outlined,
  ChargeCategory.TAX => Icons.receipt_long_outlined,
  ChargeCategory.DISCOUNT => Icons.sell_outlined,
  ChargeCategory.DEPOSIT => Icons.savings_outlined,
  ChargeCategory.MISC => Icons.more_horiz_rounded,
};

class _Consommations extends StatelessWidget {
  const _Consommations({required this.lignes});

  final List<Charge> lignes;

  @override
  Widget build(BuildContext context) {
    return _Carte(
      titre: 'Consommations',
      child: lignes.isEmpty
          ? Text(
              'Aucune consommation portée à l’ardoise.',
              style: TextStyle(fontSize: 15, color: AtriumColors.textSecondary),
            )
          : Column(
              children: [
                for (var i = 0; i < lignes.length; i++) ...[
                  if (i > 0) Divider(height: 18, color: AtriumDashColors.grid),
                  Row(
                    children: [
                      _Tuile(
                        icone: _iconeCategorie(lignes[i].categorie),
                        fond: AtriumDashColors.tileLavender,
                        encre: AtriumDashColors.tileLavenderInk,
                        taille: 38,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              lignes[i].libelle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: AtriumDashColors.title,
                              ),
                            ),
                            Text(
                              '${chargeCategoryLabel(lignes[i].categorie)}, '
                              '${_jour(lignes[i].journee)}',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: AtriumColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatAmount(lignes[i].montant),
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: AtriumDashColors.title,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}

class _Caracteristiques extends StatelessWidget {
  const _Caracteristiques({required this.chambre});

  final RoomBoardEntry chambre;

  @override
  Widget build(BuildContext context) {
    // Les trois axes, montres separement et non fondus en un seul mot : c'est
    // ce qui permet a la reception et au housekeeping de lire la meme fiche
    // sans se contredire.
    final (occupation, apOccupation) = switch (chambre.occupancy) {
      OccupancyStatus.OCCUPIED => (
        'Occupée',
        apparence(RoomDisplayStatus.OCCUPIED),
      ),
      OccupancyStatus.RESERVED => (
        'Réservée',
        apparence(RoomDisplayStatus.RESERVED),
      ),
      OccupancyStatus.VACANT => (
        'Libre',
        apparence(RoomDisplayStatus.AVAILABLE),
      ),
    };
    final (proprete, apProprete) = switch (chambre.housekeeping) {
      HousekeepingStatus.CLEAN => (
        'Propre',
        apparence(RoomDisplayStatus.AVAILABLE),
      ),
      HousekeepingStatus.INSPECTED => (
        'Inspectée',
        apparence(RoomDisplayStatus.AVAILABLE),
      ),
      HousekeepingStatus.DIRTY => (
        'À nettoyer',
        apparence(RoomDisplayStatus.CLEANING),
      ),
      HousekeepingStatus.IN_PROGRESS => (
        'Ménage en cours',
        apparence(RoomDisplayStatus.CLEANING),
      ),
    };
    final (service, apService) = chambre.isOutOfOrder
        ? ('Hors service', apparence(RoomDisplayStatus.MAINTENANCE))
        : ('En service', apparence(RoomDisplayStatus.AVAILABLE));

    return _Carte(
      titre: 'La chambre',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Ligne(cle: 'Catégorie', valeur: chambre.typeLabel),
          _Ligne(cle: 'Tarif de référence', valeur: formatAmount(chambre.rate)),
          _Ligne(cle: 'Étage', valeur: chambre.floorLabel ?? 'Non renseigné'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Axe(nom: 'Occupation', valeur: occupation, vue: apOccupation),
              _Axe(nom: 'Propreté', valeur: proprete, vue: apProprete),
              _Axe(nom: 'Service', valeur: service, vue: apService),
            ],
          ),
        ],
      ),
    );
  }
}

/// Un des trois axes de l'etat de la chambre.
class _Axe extends StatelessWidget {
  const _Axe({required this.nom, required this.valeur, required this.vue});

  final String nom;
  final String valeur;
  final ApparenceEtat vue;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
      decoration: BoxDecoration(
        color: vue.fond,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            nom,
            style: TextStyle(
              fontSize: 11.5,
              color: vue.encre.withValues(alpha: 0.8),
            ),
          ),
          Text(
            valeur,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: vue.encre,
            ),
          ),
        ],
      ),
    );
  }
}

class _Historique extends StatelessWidget {
  const _Historique({required this.sejours});

  final List<PastStay> sejours;

  @override
  Widget build(BuildContext context) {
    return _Carte(
      titre: 'Historique',
      child: sejours.isEmpty
          ? Text(
              'Aucun séjour terminé dans cette chambre.',
              style: TextStyle(fontSize: 15, color: AtriumColors.textSecondary),
            )
          : Column(
              children: [
                for (var i = 0; i < sejours.length; i++) ...[
                  if (i > 0) Divider(height: 16, color: AtriumDashColors.grid),
                  Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AtriumDashColors.control,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _initiales(sejours[i].guestName),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AtriumDashColors.title,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          sejours[i].guestName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: AtriumDashColors.title,
                          ),
                        ),
                      ),
                      Text(
                        'du ${_jour(sejours[i].arrival)} '
                        'au ${_jour(sejours[i].departure)}',
                        style: TextStyle(
                          fontSize: 13,
                          color: AtriumColors.textSecondary,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}

class _Ligne extends StatelessWidget {
  const _Ligne({required this.cle, required this.valeur});

  final String cle;
  final String valeur;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              cle,
              style: TextStyle(
                fontSize: 14.5,
                color: AtriumColors.textSecondary,
              ),
            ),
          ),
          Text(
            valeur,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: AtriumDashColors.title,
            ),
          ),
        ],
      ),
    );
  }
}

// --- Actions -----------------------------------------------------------------

class _Actions extends ConsumerWidget {
  const _Actions({required this.fiche, required this.chambre});

  final RoomDetail? fiche;
  final RoomBoardEntry chambre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sejour = fiche?.sejour;
    final attendu = fiche?.expected;

    // Le check-in n'a de sens que si un sejour attribue attend, et le
    // check-out que si quelqu'un est la. Les deux ne sont jamais proposes
    // ensemble : ce serait offrir une action impossible.
    final Widget contenu;
    if (sejour != null) {
      final ardoise = sejour.folioId;
      final boutons = <Widget>[
        _BoutonAction(
          libelle: 'Check-out',
          icone: Icons.logout_rounded,
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
        // Seulement pendant un sejour : avant l'arrivee, on reattribue depuis
        // la liste des reservations, et rien n'est encore occupe.
        _BoutonAction(
          libelle: 'Changer de chambre',
          icone: Icons.swap_horiz_rounded,
          onPressed: () async {
            final fait = await confirmChangeRoom(
              context,
              ref,
              lineId: sejour.lineId,
              guestName: sejour.guestName,
              roomNumber: chambre.number,
            );
            if (fait && context.mounted) Navigator.of(context).pop();
          },
        ),
        // Prolonger et consommer portent une ligne sur l'ardoise : il leur
        // faut une ardoise ouverte.
        if (ardoise != null)
          _BoutonAction(
            libelle: 'Prolonger',
            icone: Icons.more_time_rounded,
            onPressed: () => confirmExtendStay(
              context,
              ref,
              lineId: sejour.lineId,
              folioId: ardoise,
              guestName: sejour.guestName,
            ),
          ),
        if (ardoise != null)
          _BoutonAction(
            libelle: 'Consommation',
            icone: Icons.add_shopping_cart_rounded,
            plein: true,
            onPressed: () => showAddChargeDialog(
              context,
              folioId: ardoise,
              guestName: sejour.guestName,
            ),
          ),
      ];
      // Une grille de deux colonnes : sur une seule ligne, quatre boutons se
      // partageaient la largeur du panneau, et leur texte devenait illisible.
      contenu = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < boutons.length; i += 2) ...[
            if (i > 0) const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: boutons[i]),
                const SizedBox(width: 10),
                Expanded(
                  child: i + 1 < boutons.length
                      ? boutons[i + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ],
        ],
      );
    } else if (attendu != null) {
      contenu = SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 54),
            side: BorderSide(color: AtriumColors.mintStrong, width: 1.5),
          ),
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
          icon: const Icon(Icons.login_rounded),
          label: Text('Check-in de ${attendu.guestName}'),
        ),
      );
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        14 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: AtriumDashColors.card,
        border: Border(top: BorderSide(color: AtriumDashColors.cardBorder)),
      ),
      child: contenu,
    );
  }
}

/// Un bouton de la fiche, a la taille de sa case dans la grille.
///
/// Texte a sa taille normale, sur une ligne : reduit pour tenir, il devenait
/// illisible. `plein` marque l'action du quotidien (la consommation).
class _BoutonAction extends StatelessWidget {
  const _BoutonAction({
    required this.libelle,
    required this.icone,
    required this.onPressed,
    this.plein = false,
  });

  final String libelle;
  final IconData icone;
  final VoidCallback onPressed;
  final bool plein;

  @override
  Widget build(BuildContext context) {
    final forme = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AtriumRadii.md),
    );
    const texte = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );
    final label = Text(
      libelle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (plein) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          backgroundColor: AtriumColors.mintSoft,
          foregroundColor: AtriumColors.ink,
          shape: forme,
          textStyle: texte,
        ),
        onPressed: onPressed,
        icon: Icon(icone),
        label: label,
      );
    }
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor: AtriumDashColors.title,
        side: BorderSide(color: AtriumDashColors.cardBorder),
        shape: forme,
        textStyle: texte,
      ),
      onPressed: onPressed,
      icon: Icon(icone),
      label: label,
    );
  }
}

String _initiales(String nom) {
  final mots = nom.split(' ').where((m) => m.isNotEmpty).toList();
  if (mots.isEmpty) return '?';
  return mots.take(2).map((m) => m.characters.first.toUpperCase()).join();
}

/// « 28/09 » a partir d'une date ISO de la base.
String _jour(String iso) {
  final d = parseIsoDate(iso);
  return d == null ? iso : formatShortDate(d).substring(0, 5);
}
