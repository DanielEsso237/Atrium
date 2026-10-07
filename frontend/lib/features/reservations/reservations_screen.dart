/// Liste des reservations (cahier des charges, F1.1).
///
/// L'ecran de travail de la reception : qui arrive, qui est la, qui est
/// parti. Les filtres suivent la journee d'un receptionniste plutot que les
/// statuts bruts du modele — « attendues » regroupe les reservations en
/// attente et confirmees, parce que la distinction ne change rien a ce qu'il
/// a a faire.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';
import '../auth/session.dart';
import 'assign_room_dialog.dart';
import 'stay_actions.dart';

/// Les filtres, tels qu'un receptionniste les pense.
enum ReservationFilter {
  all('Toutes', null),
  // Les deux raccourcis de la journee : qui arrive aujourd'hui, qui doit
  // partir aujourd'hui (ou aurait deja du). C'est ce que la reception ouvre
  // le matin, pas la liste complete.
  arrivalsToday('Arrivées du jour', {
    ReservationStatus.PENDING,
    ReservationStatus.CONFIRMED,
  }, jour: ReservationDay.arrivee),
  departuresToday('Départs du jour', {
    ReservationStatus.CHECKED_IN,
  }, jour: ReservationDay.depart),
  expected('Attendues', {
    ReservationStatus.PENDING,
    ReservationStatus.CONFIRMED,
  }),
  inHouse('En cours', {ReservationStatus.CHECKED_IN}),
  done('Terminées', {
    ReservationStatus.CHECKED_OUT,
    ReservationStatus.CANCELLED,
    ReservationStatus.NO_SHOW,
  });

  const ReservationFilter(this.label, this.statuses, {this.jour});

  final String label;
  final Set<ReservationStatus>? statuses;
  final ReservationDay? jour;

  /// Vrai si la reservation passe ce filtre, pour la journee hoteliere `iso`.
  bool garde(ReservationSummary r, String iso) {
    if (statuses != null && !statuses!.contains(r.status)) return false;
    return switch (jour) {
      null => true,
      ReservationDay.arrivee => r.arrival.startsWith(iso),
      // Un depart oublie hier reste a faire aujourd'hui.
      ReservationDay.depart => r.departure.substring(0, 10).compareTo(iso) <= 0,
    };
  }
}

enum ReservationDay { arrivee, depart }

class ReservationFilterNotifier extends Notifier<ReservationFilter> {
  @override
  ReservationFilter build() => ReservationFilter.expected;

  void select(ReservationFilter f) => state = f;
}

final reservationFilterProvider =
    NotifierProvider<ReservationFilterNotifier, ReservationFilter>(
      ReservationFilterNotifier.new,
    );

/// Texte saisi dans la barre de recherche.
class ReservationSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final reservationSearchProvider = NotifierProvider<ReservationSearch, String>(
  ReservationSearch.new,
);

final reservationsProvider = StreamProvider<List<ReservationSummary>>((ref) {
  final filter = ref.watch(reservationFilterProvider);
  final search = ref.watch(reservationSearchProvider).trim().toLowerCase();

  return ref
      .watch(reservationRepositoryProvider)
      .watchReservations(statuses: filter.statuses)
      .map((list) {
        if (filter.jour != null) {
          final iso = formatIsoDate(businessDayFor(DateTime.now()));
          list = list.where((r) => filter.garde(r, iso)).toList();
        }
        if (search.isEmpty) return list;
        // La recherche porte sur ce qu'un receptionniste a sous les yeux ou
        // au telephone : un nom, une reference, un numero de chambre. Filtrer
        // ici plutot qu'en SQL garde la requete simple, et une reception ne
        // manipule jamais assez de lignes pour que ca se sente.
        return list.where((r) {
          final champs = [
            r.guestName,
            r.reference,
            r.roomNumber ?? '',
            r.roomTypeLabel,
          ].join(' ').toLowerCase();
          return champs.contains(search);
        }).toList();
      });
});

/// Toutes les reservations, sans filtre : de quoi chiffrer chaque pilule de
/// filtre avant qu'on appuie dessus.
final _toutesReservationsProvider = StreamProvider<List<ReservationSummary>>(
  (ref) => ref.watch(reservationRepositoryProvider).watchReservations(),
);

class ReservationsScreen extends ConsumerWidget {
  const ReservationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reservations = ref.watch(reservationsProvider);
    final filter = ref.watch(reservationFilterProvider);
    final toutes = ref.watch(_toutesReservationsProvider).value ?? const [];
    final recherche = ref.watch(reservationSearchProvider).trim();

    final jour = formatIsoDate(businessDayFor(DateTime.now()));
    int compte(ReservationFilter f) =>
        toutes.where((r) => f.garde(r, jour)).length;

    final arriventAujourdhui = toutes
        .where(
          (r) =>
              r.arrival.startsWith(jour) &&
              ReservationFilter.expected.statuses!.contains(r.status),
        )
        .length;
    final enCours = compte(ReservationFilter.inHouse);

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    final filtres = FilterPills<ReservationFilter>(
      selected: filter,
      onChanged: (f) => ref.read(reservationFilterProvider.notifier).select(f),
      options: [
        for (final f in ReservationFilter.values)
          FilterOption(f, f.label, count: compte(f)),
      ],
    );
    final champ = SearchPill(
      hint: 'Nom, référence, chambre…',
      onChanged: (v) => ref.read(reservationSearchProvider.notifier).update(v),
    );

    return ModuleScaffold(
      title: 'Réservations',
      subtitle:
          '$enCours séjour${enCours > 1 ? 's' : ''} en cours, '
          '$arriventAujourdhui arrivée${arriventAujourdhui > 1 ? 's' : ''} '
          "attendue${arriventAujourdhui > 1 ? 's' : ''} aujourd'hui",
      action: PillButton(
        label: 'Nouvelle réservation',
        icon: PhosphorIconsLight.plus,
        tone: PillTone.accent,
        onPressed: () => context.go('/reservations/nouvelle'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 14),
            // Les filtres prennent leur place, la recherche aussi : sur une
            // largeur de tablette ils ne tiennent pas cote a cote.
            child: LayoutBuilder(
              builder: (context, c) => c.maxWidth < 1100
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [champ, const SizedBox(height: 10), filtres],
                    )
                  : Row(
                      children: [
                        Expanded(child: filtres),
                        const SizedBox(width: 16),
                        SizedBox(width: 300, child: champ),
                      ],
                    ),
            ),
          ),
          Expanded(
            child: reservations.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(
                icon: PhosphorIconsLight.warningCircle,
                title: 'Lecture impossible',
                message: '$e',
              ),
              data: (list) => list.isEmpty
                  ? EmptyState(
                      icon: recherche.isEmpty
                          ? PhosphorIconsLight.calendarBlank
                          : PhosphorIconsLight.magnifyingGlass,
                      title: recherche.isEmpty
                          ? 'Rien dans ce filtre'
                          : 'Aucun résultat',
                      message: recherche.isEmpty
                          ? 'Aucune réservation « ${filter.label.toLowerCase()} » '
                                'pour le moment.'
                          : 'Aucune réservation ne correspond à « $recherche ».',
                      action: recherche.isEmpty
                          ? PillButton(
                              label: 'Nouvelle réservation',
                              icon: PhosphorIconsLight.plus,
                              tone: PillTone.quiet,
                              onPressed: () =>
                                  context.go('/reservations/nouvelle'),
                            )
                          : null,
                    )
                  : _Registre(reservations: list, jour: jour, marge: marge),
            ),
          ),
        ],
      ),
    );
  }
}

/// Les reservations, rangees par jour d'arrivee : c'est ainsi qu'une
/// reception lit son planning.
class _Registre extends StatelessWidget {
  const _Registre({
    required this.reservations,
    required this.jour,
    required this.marge,
  });

  final List<ReservationSummary> reservations;
  final String jour;
  final double marge;

  @override
  Widget build(BuildContext context) {
    // Grouper en gardant l'ordre de la requete.
    final groupes = <String, List<ReservationSummary>>{};
    for (final r in reservations) {
      groupes.putIfAbsent(r.arrival.substring(0, 10), () => []).add(r);
    }
    // Aujourd'hui d'abord, puis les jours a venir dans l'ordre, puis le
    // passe du plus recent au plus ancien : l'ordre dans lequel une
    // reception s'en occupe.
    final cles = groupes.keys.toList()
      ..sort((a, b) {
        final ra = a.compareTo(jour), rb = b.compareTo(jour);
        final ca = ra == 0 ? 0 : (ra > 0 ? 1 : 2);
        final cb = rb == 0 ? 0 : (rb > 0 ? 1 : 2);
        if (ca != cb) return ca - cb;
        return ca == 2 ? b.compareTo(a) : a.compareTo(b);
      });

    return LayoutBuilder(
      builder: (context, c) {
        final large = c.maxWidth >= 820;
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
          itemCount: cles.length,
          itemBuilder: (context, i) {
            final cle = cles[i];
            final lignes = groupes[cle]!;
            return FadeUp(
              index: i.clamp(0, 6),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 10),
                      child: Eyebrow(
                        _libelleJour(cle, jour),
                        trailing: Text(
                          '${lignes.length}',
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AtriumColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    Bezel(
                      radius: 26,
                      padding: const EdgeInsets.all(6),
                      child: Column(
                        children: [
                          for (var k = 0; k < lignes.length; k++) ...[
                            if (k > 0)
                              Divider(
                                height: 1,
                                indent: 18,
                                endIndent: 18,
                                color: AtriumColors.border,
                              ),
                            large
                                ? _LigneLarge(reservation: lignes[k])
                                : _LigneEtroite(reservation: lignes[k]),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

String _libelleJour(String iso, String aujourdhui) {
  final d = parseIsoDate(iso);
  final a = parseIsoDate(aujourdhui);
  if (d == null || a == null) return iso;
  final ecart = d.difference(a).inDays;
  final date = '${formatWeekdayShort(d)} ${formatDayMonth(d)}';
  return switch (ecart) {
    0 => "Arrivée aujourd'hui, $date",
    1 => 'Arrivée demain, $date',
    -1 => 'Arrivée hier, $date',
    _ => 'Arrivée $date',
  };
}

int _nuits(ReservationSummary r) {
  final a = parseIsoDate(r.arrival);
  final d = parseIsoDate(r.departure);
  return (a != null && d != null) ? d.difference(a).inDays : 0;
}

String _sejour(ReservationSummary r) {
  final a = parseIsoDate(r.arrival);
  final d = parseIsoDate(r.departure);
  return 'du ${a == null ? r.arrival : formatDayMonth(a)} au '
      '${d == null ? r.departure : formatDayMonth(d)}';
}

/// Tablette et PC : une ligne de registre, lue de gauche a droite comme la
/// fiche d'un client au comptoir.
class _LigneLarge extends ConsumerWidget {
  const _LigneLarge({required this.reservation});

  final ReservationSummary reservation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = reservation;
    final look = statusAppearance(r.status, Theme.of(context).colorScheme);
    final nuits = _nuits(r);
    return HoverRow(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Monogram(r.guestName, size: 44),
          const SizedBox(width: 14),
          Expanded(
            flex: 30,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.guestName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _styleNom,
                ),
                const SizedBox(height: 3),
                Text(
                  r.reference,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _styleDiscret,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 30,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_sejour(r), style: _styleDates),
                const SizedBox(height: 6),
                _Nuits(nuits: nuits, couleur: look.color),
              ],
            ),
          ),
          Expanded(flex: 22, child: _Chambre(reservation: r)),
          SizedBox(
            width: 124,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _Statut(label: look.label, couleur: look.color),
            ),
          ),
          SizedBox(
            width: 150,
            child: Align(
              alignment: Alignment.centerRight,
              child: _Action(reservation: r),
            ),
          ),
          SizedBox(width: 48, child: _MenuDossier(reservation: r)),
        ],
      ),
    );
  }
}

/// Telephone : l'identite en haut, le sejour, puis l'etape suivante sur
/// toute la largeur, sous le pouce.
class _LigneEtroite extends ConsumerWidget {
  const _LigneEtroite({required this.reservation});

  final ReservationSummary reservation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = reservation;
    final look = statusAppearance(r.status, Theme.of(context).colorScheme);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Monogram(r.guestName, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.guestName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _styleNom,
                    ),
                    const SizedBox(height: 2),
                    Text(r.reference, style: _styleDiscret),
                  ],
                ),
              ),
              _Statut(label: look.label, couleur: look.color),
              _MenuDossier(reservation: r),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_sejour(r), style: _styleDates),
                    const SizedBox(height: 6),
                    _Nuits(nuits: _nuits(r), couleur: look.color),
                  ],
                ),
              ),
              _Chambre(reservation: r, aDroite: true),
            ],
          ),
          if (_aUneAction(r)) ...[
            const SizedBox(height: 12),
            _Action(reservation: r, expand: true),
          ],
        ],
      ),
    );
  }
}

TextStyle get _styleNom => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 16.5,
  fontWeight: FontWeight.w700,
  letterSpacing: -0.2,
  color: AtriumColors.textPrimary,
);

/// La reference d'une reservation, en chasse fixe : elle se dicte au
/// telephone.
TextStyle get _styleDiscret => atriumCode(
  12.5,
  color: AtriumColors.textSecondary,
  weight: FontWeight.w500,
);

TextStyle get _styleDates => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 14.5,
  fontWeight: FontWeight.w600,
  color: AtriumColors.textPrimary,
  fontFeatures: tabularFigures,
);

/// Les nuits du sejour, une pastille par nuit : la duree se voit d'un coup
/// d'oeil, sans lire.
class _Nuits extends StatelessWidget {
  const _Nuits({required this.nuits, required this.couleur});

  final int nuits;
  final Color couleur;

  @override
  Widget build(BuildContext context) {
    final affichees = nuits.clamp(0, 10);
    return Row(
      children: [
        for (var i = 0; i < affichees; i++)
          Container(
            width: 14,
            height: 6,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: couleur.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const SizedBox(width: 5),
        Text(
          '$nuits nuit${nuits > 1 ? 's' : ''}',
          style: _styleDiscret.copyWith(fontSize: 12.5),
        ),
      ],
    );
  }
}

class _Chambre extends StatelessWidget {
  const _Chambre({required this.reservation, this.aDroite = false});

  final ReservationSummary reservation;
  final bool aDroite;

  @override
  Widget build(BuildContext context) {
    final r = reservation;
    return Column(
      crossAxisAlignment: aDroite
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        r.hasRoom
            ? Text(
                r.roomNumber!,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                  height: 1.1,
                  color: AtriumColors.textPrimary,
                  fontFeatures: tabularFigures,
                ),
              )
            : Tag('À attribuer', color: AtriumColors.warning),
        const SizedBox(height: 3),
        Text(
          '${r.roomTypeLabel}, ${formatAmount(r.nightlyRate)} la nuit',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _styleDiscret.copyWith(fontSize: 12.5),
        ),
      ],
    );
  }
}

/// Libelle et couleur d'un statut de sejour, pris dans les couleurs d'etat
/// de la charte : le plan des chambres et la liste disent la meme chose.
({String label, Color color}) statusAppearance(
  ReservationStatus status,
  ColorScheme schema,
) => switch (status) {
  ReservationStatus.PENDING => (
    label: 'En attente',
    color: CouleursEtat.reservee,
  ),
  ReservationStatus.CONFIRMED => (
    label: 'Confirmée',
    color: CouleursEtat.nettoyage,
  ),
  ReservationStatus.CHECKED_IN => (
    label: 'En cours',
    color: CouleursEtat.disponible,
  ),
  ReservationStatus.CHECKED_OUT => (
    label: 'Terminée',
    color: CouleursEtat.maintenance,
  ),
  ReservationStatus.CANCELLED => (
    label: 'Annulée',
    color: CouleursEtat.occupee,
  ),
  ReservationStatus.NO_SHOW => (
    label: 'Non présente',
    color: CouleursEtat.occupee,
  ),
};

/// Le statut en toutes lettres, precede de sa pastille de couleur.
class _Statut extends StatelessWidget {
  const _Statut({required this.label, required this.couleur});

  final String label;
  final Color couleur;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: couleur, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AtriumColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Les gestes rares sur un dossier, rangés derrière les trois points :
/// l'annulation n'a pas sa place à côté du check-in, ou un doigt pressé la
/// prendrait pour lui.
class _MenuDossier extends ConsumerWidget {
  const _MenuDossier({required this.reservation});

  final ReservationSummary reservation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = reservation;
    // Seulement avant l'arrivee : un client arrive part par le check-out, et
    // le serveur refuserait l'annulation.
    final annulable =
        r.status == ReservationStatus.PENDING ||
        r.status == ReservationStatus.CONFIRMED;
    final autorise = ref
        .watch(sessionProvider)
        .acces
        .peut('reservation.manage');
    if (!annulable || !autorise) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      tooltip: 'Autres actions',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (_) => confirmCancelReservation(
        context,
        ref,
        reservationId: r.id,
        guestName: r.guestName,
        reference: r.reference,
      ),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'annuler',
          child: ListTile(
            leading: Icon(Icons.event_busy_rounded),
            title: Text('Annuler la réservation'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

bool _aUneAction(ReservationSummary r) =>
    r.canCheckIn ||
    r.canCheckOut ||
    (!r.hasRoom && ReservationFilter.expected.statuses!.contains(r.status));

/// L'etape suivante du sejour, et une seule : attribuer, faire entrer ou
/// faire sortir. Un sejour termine n'en propose aucune.
class _Action extends ConsumerWidget {
  const _Action({required this.reservation, this.expand = false});

  final ReservationSummary reservation;
  final bool expand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = reservation;
    if (!r.hasRoom) {
      // Une ligne sans chambre est le seul cas qui demande une action
      // immediate de la reception : tant qu'elle n'est pas attribuee, le
      // client ne peut pas arriver.
      if (!ReservationFilter.expected.statuses!.contains(r.status)) {
        return const SizedBox.shrink();
      }
      return PillButton(
        label: 'Attribuer',
        icon: PhosphorIconsLight.door,
        tone: PillTone.quiet,
        compact: true,
        expand: expand,
        onPressed: () => showAssignRoomDialog(context, r),
      );
    }
    if (r.canCheckIn) {
      return PillButton(
        label: 'Check-in',
        icon: PhosphorIconsLight.signIn,
        tone: PillTone.accent,
        compact: true,
        expand: expand,
        onPressed: () => confirmCheckIn(
          context,
          ref,
          lineId: r.lineId,
          guestName: r.guestName,
          roomNumber: r.roomNumber!,
        ),
      );
    }
    if (r.canCheckOut) {
      return PillButton(
        label: 'Check-out',
        icon: PhosphorIconsLight.signOut,
        tone: PillTone.quiet,
        compact: true,
        expand: expand,
        onPressed: () => confirmCheckOut(
          context,
          ref,
          lineId: r.lineId,
          guestName: r.guestName,
          roomNumber: r.roomNumber!,
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
