/// La fiche d'un client, en page entiere (demande du 15 octobre).
///
/// Elle s'ouvre par-dessus la navigation, sur tout l'ecran, et se referme
/// par la croix en haut ou la touche Echap. Elle suit la base : modifiee ici
/// ou remontee d'un autre poste, elle se redessine seule.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/guest_repository.dart';
import '../../data/repositories/repository_providers.dart';
import 'guests_screen.dart';
import 'id_photos.dart';

final _ficheProvider = StreamProvider.autoDispose.family<GuestRow?, String>(
  (ref, id) => ref.watch(guestRepositoryProvider).watchGuest(id),
);

final _sejoursProvider = StreamProvider.autoDispose
    .family<List<GuestStay>, String>(
      (ref, id) => ref.watch(guestRepositoryProvider).watchStays(id),
    );

class GuestDetailScreen extends ConsumerWidget {
  const GuestDetailScreen({super.key, required this.guestId});

  final String guestId;

  /// Retour au fichier. Ouverte par un lien direct, la page n'a rien sous
  /// elle : on y va plutot que de fermer sur le vide.
  void _fermer(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/clients');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final fiche = ref.watch(_ficheProvider(guestId));
    final guest = fiche.value;
    final stats =
        ref.watch(guestStatsProvider).value?[guestId] ?? GuestStats.vide;
    final etroit = MediaQuery.sizeOf(context).width < 600;

    void modifier() => showDialog<GuestRow>(
      context: context,
      builder: (_) => GuestFormDialog(existing: guest),
    );
    void reserver() => context.go('/reservations/nouvelle?client=$guestId');

    final boutonModifier = PillButton(
      label: 'Modifier',
      icon: PhosphorIconsLight.pencilSimple,
      tone: PillTone.quiet,
      compact: true,
      onPressed: modifier,
    );
    final boutonReserver = PillButton(
      label: etroit ? 'Réserver' : 'Réserver pour ce client',
      icon: PhosphorIconsLight.calendarPlus,
      tone: PillTone.accent,
      compact: true,
      onPressed: reserver,
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _fermer(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: p.background,
          body: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _BarreHaute(
                  onFermer: () => _fermer(context),
                  actions: guest == null || etroit
                      ? const []
                      : [boutonModifier, boutonReserver],
                ),
                Expanded(
                  child: fiche.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => EmptyState(
                      icon: PhosphorIconsLight.warningCircle,
                      title: 'Lecture impossible',
                      message: '$e',
                    ),
                    data: (g) => g == null
                        ? EmptyState(
                            icon: PhosphorIconsLight.addressBook,
                            title: 'Fiche introuvable',
                            message:
                                'Elle a peut-être été supprimée depuis un '
                                'autre poste.',
                            action: PillButton(
                              label: 'Revenir au fichier',
                              icon: PhosphorIconsLight.users,
                              tone: PillTone.quiet,
                              onPressed: () => _fermer(context),
                            ),
                          )
                        : _Contenu(guest: g, stats: stats),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: etroit && guest != null
              ? SafeArea(
                  minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      Expanded(child: boutonModifier),
                      const SizedBox(width: 10),
                      Expanded(child: boutonReserver),
                    ],
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _BarreHaute extends StatelessWidget {
  const _BarreHaute({required this.onFermer, required this.actions});

  final VoidCallback onFermer;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final etroit = MediaQuery.sizeOf(context).width < 600;
    return Container(
      height: 68,
      padding: EdgeInsets.symmetric(horizontal: etroit ? 12 : 24),
      decoration: BoxDecoration(
        color: p.paper,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Fermer la fiche (Échap)',
            iconSize: 22,
            style: IconButton.styleFrom(
              backgroundColor: p.surfaceMuted,
              foregroundColor: p.text,
              minimumSize: const Size(46, 46),
            ),
            icon: const Icon(PhosphorIconsLight.x),
            onPressed: onFermer,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'Fiche client',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  color: p.text,
                ),
              ),
            ),
          ),
          for (final (i, a) in actions.indexed) ...[
            if (i > 0) const SizedBox(width: 10),
            a,
          ],
        ],
      ),
    );
  }
}

class _Contenu extends StatelessWidget {
  const _Contenu({required this.guest, required this.stats});

  final GuestRow guest;
  final GuestStats stats;

  @override
  Widget build(BuildContext context) {
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 16.0 : 32.0;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(marge, etroit ? 16 : 28, marge, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1440),
          child: LayoutBuilder(
            builder: (context, c) {
              final deuxColonnes = c.maxWidth >= 1000;
              final gauche = [
                _Coordonnees(guest: guest),
                const SizedBox(height: 20),
                _Identite(guest: guest),
                const SizedBox(height: 20),
                _Suivi(guest: guest),
              ];
              final sejours = _Sejours(guestId: guest.id);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Bandeau(guest: guest, stats: stats),
                  const SizedBox(height: 20),
                  if (deuxColonnes)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: gauche,
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(flex: 7, child: sejours),
                      ],
                    )
                  else ...[
                    sejours,
                    const SizedBox(height: 20),
                    ...gauche,
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Le bandeau : qui est le client, et ce que l'hotel sait de lui en chiffres
// ---------------------------------------------------------------------------

class _Bandeau extends StatelessWidget {
  const _Bandeau({required this.guest, required this.stats});

  final GuestRow guest;
  final GuestStats stats;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final puces = [
      for (final (l, c) in badgesClient(guest, stats, p)) _PuceBandeau(l, c),
      if (guest.syncState == SyncState.pending)
        _PuceBandeau(
          'En attente d’envoi',
          p.onHeroSoft,
          icone: PhosphorIconsLight.cloudArrowUp,
        ),
    ];
    final dernier = parseIsoDate(stats.lastArrival);

    final identite = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: p.onHero.withValues(alpha: 0.28)),
          ),
          child: Monogram(
            '${guest.firstName} ${guest.lastName}',
            size: etroit ? 60 : 80,
          ),
        ),
        SizedBox(width: etroit ? 16 : 22),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  if (guest.title != null && guest.title!.isNotEmpty)
                    guest.title!,
                  guest.firstName,
                  guest.lastName.toUpperCase(),
                ].join(' '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: etroit ? 24 : 32,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                  color: p.onHero,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [CodeCartouche(guest.code, taille: 13), ...puces],
              ),
              const SizedBox(height: 10),
              Text(
                'Client depuis le ${formatLongDate(guest.createdAt.toLocal())}',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: p.onHeroSoft,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final chiffres = [
      ('${stats.stays}', stats.stays > 1 ? 'Séjours' : 'Séjour', false),
      ('${stats.nights}', stats.nights > 1 ? 'Nuits' : 'Nuit', false),
      (dernier == null ? 'Jamais' : dateCourte(dernier), 'Dernier passage', false),
      (
        stats.openBalance > 0 ? formatAmount(stats.openBalance) : 'Rien',
        'Reste dû',
        stats.openBalance > 0,
      ),
    ];

    return Container(
      padding: EdgeInsets.all(etroit ? 20 : 28),
      decoration: BoxDecoration(
        color: p.hero,
        borderRadius: BorderRadius.circular(18),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final enLigne = c.maxWidth >= 1080;
          final bande = _Chiffres(
            chiffres: chiffres,
            colonnes: c.maxWidth >= 520 ? 4 : 2,
          );
          if (enLigne) {
            return Row(
              children: [
                Expanded(child: identite),
                const SizedBox(width: 28),
                SizedBox(width: 560, child: bande),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              identite,
              const SizedBox(height: 22),
              Container(height: 1, color: p.onHero.withValues(alpha: 0.16)),
              const SizedBox(height: 18),
              bande,
            ],
          );
        },
      ),
    );
  }
}

/// Les chiffres du client, poses sur le bandeau, separes par des filets.
class _Chiffres extends StatelessWidget {
  const _Chiffres({required this.chiffres, required this.colonnes});

  final List<(String valeur, String libelle, bool marque)> chiffres;
  final int colonnes;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    Widget chiffre((String, String, bool) c) {
      final (valeur, libelle, marque) = c;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              valeur,
              maxLines: 1,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                // Ce qui reste a encaisser : la seule touche de laiton.
                color: marque ? p.heroAccent : p.onHero,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            libelle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: p.onHeroSoft,
            ),
          ),
        ],
      );
    }

    final filet = Container(
      width: 1,
      height: 46,
      margin: const EdgeInsets.symmetric(horizontal: 18),
      color: p.onHero.withValues(alpha: 0.16),
    );
    final rangees = <List<(String, String, bool)>>[
      for (var i = 0; i < chiffres.length; i += colonnes)
        chiffres.sublist(i, (i + colonnes).clamp(0, chiffres.length)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, rangee) in rangees.indexed) ...[
          if (i > 0) const SizedBox(height: 18),
          Row(
            children: [
              for (final (j, c) in rangee.indexed) ...[
                if (j > 0) filet,
                Expanded(child: chiffre(c)),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// Une etiquette d'etat sur le bandeau bleu : une pastille de couleur et un
/// libelle blanc -- une etiquette claire y ferait une tache.
class _PuceBandeau extends StatelessWidget {
  const _PuceBandeau(this.libelle, this.couleur, {this.icone});

  final String libelle;
  final Color couleur;
  final IconData? icone;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    // La couleur d'etat eclaircie : sombre, elle disparaitrait sur le bleu.
    final vive = Color.lerp(couleur, Colors.white, 0.45)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: p.onHero.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.onHero.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icone != null)
            Icon(icone, size: 15, color: vive)
          else
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: vive, shape: BoxShape.circle),
            ),
          const SizedBox(width: 7),
          Text(
            libelle,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.onHero,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Les panneaux
// ---------------------------------------------------------------------------

class _Panneau extends StatelessWidget {
  const _Panneau({required this.titre, required this.child, this.trailing});

  final String titre;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Bezel(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(titre, trailing: trailing),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Une ligne d'information : l'icone, ce que c'est, ce que ca vaut.
class _Info extends StatelessWidget {
  const _Info(this.icone, this.cle, this.valeur, {this.fin});

  final IconData icone;
  final String cle;
  final String? valeur;
  final Widget? fin;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final absent = valeur == null || valeur!.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: p.surfaceMuted,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icone, size: 19, color: p.textOnMuted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cle,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: p.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  absent ? 'Non renseigné' : valeur!,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15,
                    fontWeight: absent ? FontWeight.w500 : FontWeight.w600,
                    color: absent ? p.placeholder : p.text,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ],
            ),
          ),
          ?fin,
        ],
      ),
    );
  }
}

class _Coordonnees extends StatelessWidget {
  const _Coordonnees({required this.guest});

  final GuestRow guest;

  @override
  Widget build(BuildContext context) {
    final g = guest;
    final ville = [g.postalCode, g.city].whereType<String>().join(' ').trim();
    final adresse = [
      g.address,
      if (ville.isNotEmpty) ville,
      g.country,
    ].whereType<String>().where((s) => s.trim().isNotEmpty).join(', ');
    return _Panneau(
      titre: 'Coordonnées',
      child: Column(
        children: [
          _Info(PhosphorIconsLight.phone, 'Téléphone', g.phone),
          if (g.phoneAlt != null && g.phoneAlt!.isNotEmpty)
            _Info(PhosphorIconsLight.deviceMobile, 'Autre numéro', g.phoneAlt),
          _Info(PhosphorIconsLight.envelopeSimple, 'Courriel', g.email),
          _Info(
            PhosphorIconsLight.mapPin,
            'Adresse',
            adresse.isEmpty ? null : adresse,
          ),
        ],
      ),
    );
  }
}

class _Identite extends StatelessWidget {
  const _Identite({required this.guest});

  final GuestRow guest;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final g = guest;
    final naissance = parseIsoDate(g.birthDate);
    final lieu = g.birthPlace?.trim();
    final ne = [
      if (naissance != null) 'Le ${formatShortDate(naissance)}',
      if (lieu != null && lieu.isNotEmpty)
        naissance == null ? 'À $lieu' : 'à $lieu',
    ].join(' ');
    final expiration = parseIsoDate(g.idDocumentExpiry);
    // Comparees en texte : deux dates seules, sans fuseau a appliquer.
    final expiree =
        g.idDocumentExpiry != null &&
        g.idDocumentExpiry!.compareTo(businessDateNow()) < 0;
    return _Panneau(
      titre: 'Identité',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Info(PhosphorIconsLight.globe, 'Nationalité', g.nationality),
          if (ne.isNotEmpty)
            _Info(PhosphorIconsLight.calendarBlank, 'Naissance', ne),
          _Info(
            PhosphorIconsLight.identificationCard,
            g.idDocumentType == null
                ? "Pièce d'identité"
                : libellePiece(g.idDocumentType!),
            g.idDocumentNumber,
          ),
          if (expiration != null)
            _Info(
              PhosphorIconsLight.hourglass,
              'Valable jusqu’au',
              formatLongDate(expiration),
              fin: expiree ? Tag('Expirée', color: p.error) : null,
            ),
          // Alignees sur le texte des lignes, pas sur leurs icones.
          Padding(
            padding: const EdgeInsets.only(left: 50, top: 6, bottom: 8),
            child: IdPhotoPair(guestId: g.id),
          ),
        ],
      ),
    );
  }
}

/// Ce que la reception doit savoir avant de servir : le plafond, la liste
/// noire et ses raisons, les notes, et si la fiche est connue du serveur.
class _Suivi extends StatelessWidget {
  const _Suivi({required this.guest});

  final GuestRow guest;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final g = guest;
    final notes = g.notes?.trim() ?? '';
    final raison = g.blacklistReason?.trim() ?? '';
    return _Panneau(
      titre: 'Compte et suivi',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (g.isBlacklisted)
            Container(
              margin: const EdgeInsets.only(top: 6, bottom: 6),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: p.errorTint,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.error.withValues(alpha: 0.35)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    PhosphorIconsLight.warningDiamond,
                    size: 20,
                    color: p.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      raison.isEmpty
                          ? 'Client sur liste noire.'
                          : 'Client sur liste noire : $raison',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          _Info(
            PhosphorIconsLight.wallet,
            'Plafond de crédit',
            // `0` veut dire sans limite, pas « tout refuser ».
            g.creditLimit == 0 ? 'Sans plafond' : formatAmount(g.creditLimit),
          ),
          _Info(
            g.syncState == SyncState.pending
                ? PhosphorIconsLight.cloudArrowUp
                : PhosphorIconsLight.cloudCheck,
            'Serveur',
            g.syncState == SyncState.pending
                ? 'En attente d’envoi : la fiche n’existe encore que sur '
                      'cette tablette'
                : 'Fiche enregistrée sur le serveur',
          ),
          if (notes.isNotEmpty)
            _Info(PhosphorIconsLight.info, 'Notes', notes),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Les sejours
// ---------------------------------------------------------------------------

(String, Color) _etatSejour(String statut, AtriumPalette p) => switch (statut) {
  'CHECKED_IN' => ('En cours', p.success),
  'CHECKED_OUT' => ('Terminé', p.textSecondary),
  'CANCELLED' => ('Annulé', p.error),
  'NO_SHOW' => ('Non présenté', p.error),
  'CONFIRMED' => ('Confirmé', p.accent),
  _ => ('En attente', p.warning),
};

String _periode(GuestStay s) {
  final a = parseIsoDate(s.arrival);
  final d = parseIsoDate(s.departure);
  if (a == null) return s.arrival;
  if (s.hourly || d == null) return 'Le ${dateCourte(a)}';
  return a.year == d.year
      ? 'Du ${formatDayMonth(a)} au ${dateCourte(d)}'
      : 'Du ${dateCourte(a)} au ${dateCourte(d)}';
}

class _Sejours extends ConsumerWidget {
  const _Sejours({required this.guestId});

  final String guestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final sejours = ref.watch(_sejoursProvider(guestId)).value;
    final nombre = sejours?.length ?? 0;
    return _Panneau(
      titre: 'Séjours',
      trailing: sejours == null
          ? null
          : Text(
              nombre == 0
                  ? 'Aucun'
                  : '$nombre réservation${nombre > 1 ? 's' : ''}',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
                fontFeatures: tabularFigures,
              ),
            ),
      child: sejours == null
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          : sejours.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Column(
                children: [
                  Icon(
                    PhosphorIconsLight.calendarBlank,
                    size: 30,
                    color: p.placeholder,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Aucun séjour pour l’instant. Réservez depuis le bouton '
                    'en haut de la page.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 14,
                      height: 1.4,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            )
          : LayoutBuilder(
              builder: (context, c) {
                final large = c.maxWidth >= 600;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (large) const _EnTeteSejours(),
                    for (final (i, s) in sejours.indexed)
                      _LigneSejour(
                        sejour: s,
                        large: large,
                        filet: i < sejours.length - 1,
                      ),
                  ],
                );
              },
            ),
    );
  }
}

const _flexSejour = [34, 22, 12, 18, 14];

class _EnTeteSejours extends StatelessWidget {
  const _EnTeteSejours();

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final style = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: p.textSecondary,
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          for (final (i, t) in [
            'Dates',
            'Chambre',
            'Durée',
            'Référence',
            'État',
          ].indexed)
            Expanded(
              flex: _flexSejour[i],
              child: Text(t, style: style),
            ),
        ],
      ),
    );
  }
}

class _LigneSejour extends StatelessWidget {
  const _LigneSejour({
    required this.sejour,
    required this.large,
    required this.filet,
  });

  final GuestStay sejour;
  final bool large;
  final bool filet;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final s = sejour;
    final (etat, couleur) = _etatSejour(s.status, p);
    final principal = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
      color: p.text,
      fontFeatures: tabularFigures,
    );
    final second = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 12.5,
      fontWeight: FontWeight.w500,
      color: p.textSecondary,
      fontFeatures: tabularFigures,
    );
    final chambre = s.roomNumber == null
        ? 'Non attribuée'
        : 'Chambre ${s.roomNumber}';
    final duree = s.hourly
        ? 'En heures'
        : '${s.nights} nuit${s.nights > 1 ? 's' : ''}';

    Widget texte(String t, TextStyle style) =>
        Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);

    final decoration = BoxDecoration(
      border: filet ? Border(bottom: BorderSide(color: p.grid)) : null,
    );

    if (!large) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: decoration,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  texte(_periode(s), principal),
                  const SizedBox(height: 3),
                  texte(
                    '$chambre, ${duree.toLowerCase()}, ${s.reference}',
                    second,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Tag(etat, color: couleur),
          ],
        ),
      );
    }

    final cellules = <Widget>[
      texte(_periode(s), principal),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          texte(
            chambre,
            s.roomNumber == null
                ? principal.copyWith(
                    color: p.placeholder,
                    fontWeight: FontWeight.w500,
                  )
                : principal,
          ),
          if (s.roomType != null) ...[
            const SizedBox(height: 2),
            texte(s.roomType!, second),
          ],
        ],
      ),
      texte(duree, principal.copyWith(fontWeight: FontWeight.w500)),
      Align(
        alignment: Alignment.centerLeft,
        child: CodeCartouche(s.reference, taille: 11.5),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Tag(etat, color: couleur),
      ),
    ];
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: decoration,
      child: Row(
        children: [
          for (final (i, cellule) in cellules.indexed)
            Expanded(
              flex: _flexSejour[i],
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: cellule,
              ),
            ),
        ],
      ),
    );
  }
}
