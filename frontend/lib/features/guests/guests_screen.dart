/// Fichier clients (cahier des charges, F1.6).
///
/// Le fichier en tableau, de A a Z, sur toute la largeur ; la fiche d'un
/// client s'ouvre en page entiere (`guest_detail_screen.dart`).
///
/// C'est le premier ecran ou la reception **ecrit**. La fiche part dans Drift
/// et dans la file d'attente en une seule transaction, sans attendre le
/// reseau : le client est enregistre meme si le Wi-Fi est tombe.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/recherche.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/guest_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import 'guest_rules.dart';
import '../../core/ui/confirmation.dart';

/// Texte saisi dans la barre de recherche.
///
/// Un `Notifier` et non un `StateProvider` : celui-ci a disparu en Riverpod 3.
class GuestSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final guestSearchProvider = NotifierProvider<GuestSearch, String>(
  GuestSearch.new,
);

/// Tout le fichier : la recherche se fait a l'ecran, avec la regle commune
/// (`core/recherche.dart`), pour que les compteurs des filtres la suivent.
final guestsProvider = StreamProvider<List<GuestRow>>(
  (ref) => ref.watch(guestRepositoryProvider).watchGuests(),
);

/// Les chiffres de chaque client. Libere en quittant l'ecran : la date
/// d'exploitation qui borne les arrivees a venir est relue au retour.
final guestStatsProvider =
    StreamProvider.autoDispose<Map<String, GuestStats>>(
      (ref) => ref
          .watch(guestRepositoryProvider)
          .watchGuestStats(businessDate: businessDateNow()),
    );

enum _Filtre { tous, enSejour, attendus, resteDu, vip }

class _FiltreClients extends Notifier<_Filtre> {
  @override
  _Filtre build() => _Filtre.tous;

  void choisir(_Filtre f) => state = f;
}

final _filtreProvider = NotifierProvider<_FiltreClients, _Filtre>(
  _FiltreClients.new,
);

bool _garde(_Filtre f, GuestRow g, GuestStats s) => switch (f) {
  _Filtre.tous => true,
  _Filtre.enSejour => s.currentRoom != null,
  _Filtre.attendus => s.nextArrival != null,
  _Filtre.resteDu => s.openBalance > 0,
  _Filtre.vip => g.isVip,
};

String libellePiece(IdDocumentType t) => switch (t) {
  IdDocumentType.ID_CARD => "Carte d'identité",
  IdDocumentType.PASSPORT => 'Passeport',
  IdDocumentType.DRIVING_LICENSE => 'Permis de conduire',
  IdDocumentType.RESIDENCE_PERMIT => 'Titre de séjour',
  IdDocumentType.OTHER => 'Autre pièce',
};

/// La lettre sous laquelle un client se range : celle de son nom, sans
/// accent. « Ékamé » se cherche a E, pas apres Z.
String initialeClient(GuestRow g) {
  final nom = sansAccents(g.lastName.trim());
  if (nom.isEmpty) return '#';
  final l = nom[0].toUpperCase();
  return RegExp('[A-Z]').hasMatch(l) ? l : '#';
}

/// L'ordre du fichier : nom puis prenom, sans accents ni majuscules. SQLite
/// range par octets -- les minuscules et les accents finissaient apres Z.
int comparerClients(GuestRow a, GuestRow b) {
  final la = initialeClient(a), lb = initialeClient(b);
  // Les noms qui ne commencent pas par une lettre passent en fin de liste.
  if (la != lb && (la == '#' || lb == '#')) return la == '#' ? 1 : -1;
  final n = sansAccents(a.lastName.trim()).compareTo(
    sansAccents(b.lastName.trim()),
  );
  if (n != 0) return n;
  return sansAccents(a.firstName.trim()).compareTo(
    sansAccents(b.firstName.trim()),
  );
}

/// Ouvre la fiche en page entiere, par-dessus la navigation.
void ouvrirFicheClient(BuildContext context, String guestId) =>
    context.push('/clients/$guestId');

class GuestsScreen extends ConsumerWidget {
  const GuestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guests = ref.watch(guestsProvider);
    final stats = ref.watch(guestStatsProvider).value ?? const {};
    final saisie = ref.watch(guestSearchProvider);
    final recherche = Recherche(saisie);
    final filtre = ref.watch(_filtreProvider);
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    void nouveau() => showDialog<void>(
      context: context,
      builder: (_) => const GuestFormDialog(),
    );

    // La recherche d'abord, le filtre ensuite : chaque pilule dit combien
    // elle garderait de ce qu'on a deja cherche.
    final trouves = [
      for (final g in guests.value ?? const <GuestRow>[])
        if (recherche.garde([
          g.lastName,
          g.firstName,
          g.code,
          g.phone,
          g.phoneAlt,
          g.email,
          g.nationality,
          g.idDocumentNumber,
          stats[g.id]?.currentRoom,
        ]))
          g,
    ]..sort(comparerClients);
    int compte(_Filtre f) => trouves
        .where((g) => _garde(f, g, stats[g.id] ?? GuestStats.vide))
        .length;
    final vip = compte(_Filtre.vip);
    // Un filtre VIP vide n'a rien a montrer ; on ne le propose que s'il sert.
    final filtreEffectif = filtre == _Filtre.vip && vip == 0
        ? _Filtre.tous
        : filtre;
    final visibles = [
      for (final g in trouves)
        if (_garde(filtreEffectif, g, stats[g.id] ?? GuestStats.vide)) g,
    ];
    final total = guests.value?.length;

    final outils = [
      SearchPill(
        hint: 'Nom, téléphone, pièce, chambre…',
        onChanged: (v) => ref.read(guestSearchProvider.notifier).update(v),
      ),
      FilterPills<_Filtre>(
        selected: filtreEffectif,
        onChanged: ref.read(_filtreProvider.notifier).choisir,
        options: [
          FilterOption(_Filtre.tous, 'Tous', count: trouves.length),
          FilterOption(
            _Filtre.enSejour,
            'En séjour',
            count: compte(_Filtre.enSejour),
            color: AtriumPalette.current.success,
          ),
          FilterOption(
            _Filtre.attendus,
            'Arrivée prévue',
            count: compte(_Filtre.attendus),
            color: AtriumPalette.current.accent,
          ),
          FilterOption(
            _Filtre.resteDu,
            'Reste dû',
            count: compte(_Filtre.resteDu),
            color: AtriumPalette.current.warning,
          ),
          if (vip > 0)
            FilterOption(
              _Filtre.vip,
              'VIP',
              count: vip,
              color: AtriumPalette.brass,
            ),
        ],
      ),
    ];

    return ModuleScaffold(
      title: 'Clients',
      subtitle: total == null
          ? null
          : recherche.vide
          ? '$total fiche${total > 1 ? 's' : ''} au fichier, de A à Z'
          : '${trouves.length} résultat${trouves.length > 1 ? 's' : ''} '
                'pour « ${saisie.trim()} »',
      action: PillButton(
        label: 'Nouveau client',
        icon: PhosphorIconsLight.userPlus,
        tone: PillTone.accent,
        onPressed: nouveau,
      ),
      body: Padding(
        padding: EdgeInsets.fromLTRB(marge, 0, marge, etroit ? 12 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, c) => c.maxWidth >= 1100
                  ? Row(
                      children: [
                        SizedBox(width: 380, child: outils[0]),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: outils[1],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [outils[0], const SizedBox(height: 10), outils[1]],
                    ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: guests.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => EmptyState(
                  icon: PhosphorIconsLight.warningCircle,
                  title: 'Lecture impossible',
                  message: '$e',
                ),
                data: (_) => visibles.isEmpty
                    ? EmptyState(
                        icon: total == 0
                            ? PhosphorIconsLight.addressBook
                            : PhosphorIconsLight.magnifyingGlass,
                        title: total == 0
                            ? 'Fichier vide'
                            : 'Aucun client ne correspond',
                        message: total == 0
                            ? 'Les fiches se créent ici ou à la volée '
                                  'depuis une réservation.'
                            : filtreEffectif != _Filtre.tous
                            ? 'Aucun client de ce filtre ne répond à la '
                                  'recherche. Revenez à Tous.'
                            : 'Vérifiez l’orthographe, ou créez la fiche.',
                        action: PillButton(
                          label: 'Nouveau client',
                          icon: PhosphorIconsLight.userPlus,
                          tone: PillTone.quiet,
                          onPressed: nouveau,
                        ),
                      )
                    : _Tableau(clients: visibles, stats: stats),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Le tableau
// ---------------------------------------------------------------------------

/// Les colonnes, de la plus utile a la plus accessoire : on retire par la
/// fin quand la largeur manque, jamais le nom ni l'etat.
enum _Colonne {
  client('Client', 30),
  contact('Contact', 25),
  piece("Pièce d'identité", 20),
  nationalite('Nationalité', 14),
  sejours('Séjours', 21),
  etat('État', 22);

  const _Colonne(this.titre, this.flex);

  final String titre;
  final int flex;
}

List<_Colonne> _colonnesPour(double largeur) => [
  _Colonne.client,
  if (largeur >= 640) _Colonne.contact,
  if (largeur >= 900) _Colonne.piece,
  if (largeur >= 1120) _Colonne.nationalite,
  if (largeur >= 780) _Colonne.sejours,
  _Colonne.etat,
];

/// Sur telephone, il ne reste que le client et son etat : le nom prend la
/// place, l'etat se serre.
int _flex(_Colonne c, List<_Colonne> colonnes) => colonnes.length > 2
    ? c.flex
    : c == _Colonne.client
    ? 64
    : 36;

/// Une ligne du tableau : l'en-tete d'une lettre, ou un client.
class _Entree {
  const _Entree.lettre(this.lettre, this.nombre) : guest = null, derniere = false;
  const _Entree.client(GuestRow this.guest, {required this.derniere})
    : lettre = null,
      nombre = 0;

  final String? lettre;
  final int nombre;
  final GuestRow? guest;

  /// Derniere ligne de sa lettre : pas de filet dessous, la bande de la
  /// lettre suivante en tient lieu.
  final bool derniere;
}

class _Tableau extends StatefulWidget {
  const _Tableau({required this.clients, required this.stats});

  /// Deja tries de A a Z.
  final List<GuestRow> clients;
  final Map<String, GuestStats> stats;

  @override
  State<_Tableau> createState() => _TableauState();
}

class _TableauState extends State<_Tableau> {
  /// Hauteurs fixes : la position de chaque lettre se calcule sans mesurer,
  /// et l'index l'atteint d'un geste meme a mille fiches.
  static const _hLettre = 38.0;
  static const _hLigne = 70.0;

  final _defilement = ScrollController();
  final _lettreVisible = ValueNotifier<String?>(null);
  var _entrees = <_Entree>[];
  var _positions = <String, double>{};

  @override
  void initState() {
    super.initState();
    _preparer();
    _defilement.addListener(_suivre);
  }

  @override
  void didUpdateWidget(_Tableau ancien) {
    super.didUpdateWidget(ancien);
    if (!identical(ancien.clients, widget.clients)) _preparer();
  }

  @override
  void dispose() {
    _defilement.dispose();
    _lettreVisible.dispose();
    super.dispose();
  }

  void _preparer() {
    final groupes = <String, List<GuestRow>>{};
    for (final g in widget.clients) {
      groupes.putIfAbsent(initialeClient(g), () => []).add(g);
    }
    final entrees = <_Entree>[];
    final positions = <String, double>{};
    var y = 0.0;
    for (final MapEntry(key: lettre, value: groupe) in groupes.entries) {
      positions[lettre] = y;
      entrees.add(_Entree.lettre(lettre, groupe.length));
      y += _hLettre;
      for (var i = 0; i < groupe.length; i++) {
        entrees.add(
          _Entree.client(groupe[i], derniere: i == groupe.length - 1),
        );
        y += _hLigne;
      }
    }
    _entrees = entrees;
    _positions = positions;
    _suivre();
  }

  /// La lettre en haut de la fenetre, que l'index allume.
  void _suivre() {
    final y = _defilement.hasClients ? _defilement.offset : 0.0;
    String? visible;
    for (final MapEntry(key: l, value: debut) in _positions.entries) {
      if (debut <= y + 1) visible = l;
    }
    _lettreVisible.value = visible ?? _positions.keys.firstOrNull;
  }

  void _aller(String lettre, {required bool glisse}) {
    final debut = _positions[lettre];
    if (debut == null || !_defilement.hasClients) return;
    final cible = debut.clamp(0.0, _defilement.position.maxScrollExtent);
    if (glisse || MediaQuery.disableAnimationsOf(context)) {
      // Le doigt qui parcourt l'index sent chaque lettre franchie.
      if (glisse && lettre != _lettreVisible.value) {
        HapticFeedback.selectionClick();
      }
      _defilement.jumpTo(cible);
    } else {
      _defilement.animateTo(
        cible,
        duration: const Duration(milliseconds: 420),
        curve: atriumSpring,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return LayoutBuilder(
      builder: (context, c) {
        final colonnes = _colonnesPour(c.maxWidth - 34);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Bezel(
                radius: 22,
                padding: EdgeInsets.zero,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _EnTete(colonnes: colonnes),
                      Expanded(
                        child: ListView.builder(
                            controller: _defilement,
                            padding: EdgeInsets.zero,
                            itemCount: _entrees.length,
                            itemExtentBuilder: (i, _) => i >= _entrees.length
                                ? null
                                : _entrees[i].lettre != null
                                ? _hLettre
                                : _hLigne,
                            itemBuilder: (context, i) {
                              final e = _entrees[i];
                              if (e.lettre != null) {
                                return _BandeLettre(
                                  lettre: e.lettre!,
                                  nombre: e.nombre,
                                );
                              }
                              final g = e.guest!;
                              return _LigneClient(
                                guest: g,
                                stats: widget.stats[g.id] ?? GuestStats.vide,
                                colonnes: colonnes,
                                filet: !e.derniere,
                                onTap: () => ouvrirFicheClient(context, g.id),
                              );
                            },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 28,
              child: Padding(
                padding: const EdgeInsets.only(top: 46),
                child: _IndexAlphabet(
                  presentes: _positions.keys.toSet(),
                  active: _lettreVisible,
                  couleur: p,
                  onLettre: _aller,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

TextStyle _styleTitreColonne(AtriumPalette p) => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 13,
  fontWeight: FontWeight.w600,
  color: p.textSecondary,
);

class _EnTete extends StatelessWidget {
  const _EnTete({required this.colonnes});

  final List<_Colonne> colonnes;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          for (final c in colonnes)
            Expanded(
              flex: _flex(c, colonnes),
              child: Padding(
                // Le titre de la colonne Client s'aligne sur le nom, pas sur
                // la vignette.
                padding: EdgeInsets.only(
                  left: c == _Colonne.client ? 52 : 0,
                  right: 12,
                ),
                child: Text(
                  c.titre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _styleTitreColonne(p),
                ),
              ),
            ),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

/// La bande d'une lettre : on sait ou l'on est dans l'alphabet.
class _BandeLettre extends StatelessWidget {
  const _BandeLettre({required this.lettre, required this.nombre});

  final String lettre;
  final int nombre;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: p.accentTint,
        border: Border.symmetric(horizontal: BorderSide(color: p.grid)),
      ),
      child: Row(
        children: [
          Semantics(
            header: true,
            child: Text(
              lettre,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: p.accent,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '$nombre client${nombre > 1 ? 's' : ''}',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: p.textSecondary,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}

class _LigneClient extends StatelessWidget {
  const _LigneClient({
    required this.guest,
    required this.stats,
    required this.colonnes,
    required this.filet,
    required this.onTap,
  });

  final GuestRow guest;
  final GuestStats stats;
  final List<_Colonne> colonnes;
  final bool filet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final nom = '${guest.lastName.toUpperCase()} ${guest.firstName}'.trim();
    return Semantics(
      button: true,
      label: 'Ouvrir la fiche de $nom',
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: filet
              ? Border(bottom: BorderSide(color: p.grid))
              : const Border(),
        ),
        child: HoverRow(
          onTap: onTap,
          radius: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              for (final c in colonnes)
                Expanded(
                  flex: _flex(c, colonnes),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _cellule(c, p, nom),
                  ),
                ),
              SizedBox(
                width: 24,
                // Une fiche creee hors ligne se signale : la reception doit
                // savoir ce qui est deja connu du serveur et ce qui ne l'est
                // pas encore.
                child: guest.syncState == SyncState.pending
                    ? Tooltip(
                        message: 'En attente d’envoi au serveur',
                        child: Icon(
                          PhosphorIconsLight.cloudArrowUp,
                          size: 20,
                          color: p.accent,
                        ),
                      )
                    : Icon(
                        PhosphorIconsLight.caretRight,
                        size: 18,
                        color: p.placeholder,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cellule(_Colonne c, AtriumPalette p, String nom) {
    final principal = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14,
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
    final absent = second.copyWith(color: p.placeholder);

    Widget deuxLignes(String haut, String? bas, {TextStyle? styleHaut}) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              haut,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: styleHaut ?? principal,
            ),
            if (bas != null && bas.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                bas,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: second,
              ),
            ],
          ],
        );

    switch (c) {
      case _Colonne.client:
        // Sans colonne Contact, le telephone passe sous le nom.
        final sansContact = !colonnes.contains(_Colonne.contact);
        return Row(
          children: [
            Monogram('${guest.firstName} ${guest.lastName}', size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    nom,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: principal.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  LigneCode(
                    guest.code,
                    detail: sansContact ? guest.phone : null,
                  ),
                ],
              ),
            ),
          ],
        );
      case _Colonne.contact:
        if (guest.phone == null && guest.email == null) {
          return Text('Non renseigné', style: absent);
        }
        return deuxLignes(guest.phone ?? guest.email!, guest.phone == null ? null : guest.email);
      case _Colonne.piece:
        if (guest.idDocumentNumber == null) {
          return Text('Aucune pièce', style: absent);
        }
        return deuxLignes(
          guest.idDocumentNumber!,
          guest.idDocumentType == null
              ? null
              : libellePiece(guest.idDocumentType!),
        );
      case _Colonne.nationalite:
        return Text(
          guest.nationality ?? 'Non renseignée',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: guest.nationality == null ? absent : principal,
        );
      case _Colonne.sejours:
        if (stats.stays == 0) return Text('Aucun', style: absent);
        final dernier = parseIsoDate(stats.lastArrival);
        return deuxLignes(
          '${stats.stays} séjour${stats.stays > 1 ? 's' : ''}',
          dernier == null ? null : 'Dernier le ${dateCourte(dernier)}',
        );
      case _Colonne.etat:
        final badges = badgesClient(guest, stats, p);
        if (badges.isEmpty) return const SizedBox.shrink();
        return ClipRect(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final (l, couleur) in badges.take(3)) Tag(l, color: couleur)],
          ),
        );
    }
  }
}

/// « 12 oct. 2026 » : le jour et le mois en lettres, l'annee en clair.
String dateCourte(DateTime d) => '${formatDayMonth(d)} ${d.year}';

/// L'etat d'un client en quelques etiquettes, de la plus pressante a la plus
/// anodine : la liste noire d'abord, la chambre ou il dort, ce qu'il doit.
List<(String, Color)> badgesClient(
  GuestRow g,
  GuestStats s,
  AtriumPalette p,
) {
  final prochaine = parseIsoDate(s.nextArrival);
  return [
    if (g.isBlacklisted) ('Liste noire', p.error),
    if (s.currentRoom != null)
      ('En chambre ${s.currentRoom}', p.success)
    else if (prochaine != null)
      ('Arrive le ${formatDayMonth(prochaine)}', p.accent),
    if (s.openBalance > 0) ('Doit ${formatAmountShort(s.openBalance)}', p.warning),
    if (g.isVip) ('VIP', AtriumPalette.brass),
  ];
}

/// L'index de A a Z, le long du tableau : un appui saute a la lettre, un
/// glisse du doigt parcourt l'alphabet. Les lettres sans client restent
/// visibles, en retrait : l'alphabet garde sa forme et l'oeil ses reperes.
class _IndexAlphabet extends StatelessWidget {
  const _IndexAlphabet({
    required this.presentes,
    required this.active,
    required this.couleur,
    required this.onLettre,
  });

  final Set<String> presentes;
  final ValueListenable<String?> active;
  final AtriumPalette couleur;
  final void Function(String lettre, {required bool glisse}) onLettre;

  static final _alphabet = [
    for (var c = 65; c <= 90; c++) String.fromCharCode(c),
    '#',
  ];

  @override
  Widget build(BuildContext context) {
    final p = couleur;
    return LayoutBuilder(
      builder: (context, c) {
        var lettres = _alphabet;
        var h = (c.maxHeight / lettres.length).clamp(0.0, 24.0);
        // Trop court pour tout l'alphabet (telephone couche) : les seules
        // lettres utiles.
        if (h < 14) {
          lettres = [for (final l in _alphabet) if (presentes.contains(l)) l];
          h = (c.maxHeight / lettres.length.clamp(1, 99)).clamp(0.0, 24.0);
        }

        void viser(double y, {required bool glisse}) {
          if (h <= 0) return;
          final i = (y / h).floor().clamp(0, lettres.length - 1);
          if (presentes.contains(lettres[i])) {
            onLettre(lettres[i], glisse: glisse);
          }
        }

        return Semantics(
          container: true,
          label: 'Index alphabétique',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => viser(d.localPosition.dy, glisse: false),
            onVerticalDragUpdate: (d) => viser(d.localPosition.dy, glisse: true),
            child: ValueListenableBuilder<String?>(
              valueListenable: active,
              builder: (context, actif, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final l in lettres)
                    SizedBox(
                      height: h,
                      child: Center(
                        child: _LettreIndex(
                          lettre: l,
                          presente: presentes.contains(l),
                          active: l == actif,
                          taille: h,
                          palette: p,
                          onTap: () => onLettre(l, glisse: false),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LettreIndex extends StatelessWidget {
  const _LettreIndex({
    required this.lettre,
    required this.presente,
    required this.active,
    required this.taille,
    required this.palette,
    required this.onTap,
  });

  final String lettre;
  final bool presente;
  final bool active;
  final double taille;
  final AtriumPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final cote = (taille - 2).clamp(12.0, 22.0);
    return Semantics(
      button: presente,
      selected: active,
      label: presente ? 'Lettre $lettre' : null,
      onTap: presente ? onTap : null,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: AtriumMotion.of(context, const Duration(milliseconds: 220)),
        curve: atriumSpring,
        width: cote,
        height: cote,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? p.selected : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Text(
          lettre,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: (cote * 0.56).clamp(9.0, 12.0),
            fontWeight: presente ? FontWeight.w700 : FontWeight.w500,
            color: active
                ? p.onSelected
                : presente
                ? p.accent
                : p.placeholder.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

/// Creer une fiche, ou modifier celle qu'on lui passe.
///
/// Un seul formulaire pour les deux, mais pas les memes exigences : a la
/// creation, les regles de `guest_rules.dart` ; a la modification, nom et
/// prenom seulement. Un client ancien sans telephone ni piece doit pouvoir
/// etre corrige tel quel -- l'obliger a tout remplir le rendrait intouchable
/// le jour ou il n'a pas ses papiers.
class GuestFormDialog extends ConsumerStatefulWidget {
  const GuestFormDialog({super.key, this.existing});

  final GuestRow? existing;

  @override
  ConsumerState<GuestFormDialog> createState() => _GuestFormDialogState();
}

class _GuestFormDialogState extends ConsumerState<GuestFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _firstName = TextEditingController(
    text: widget.existing?.firstName,
  );
  late final _lastName = TextEditingController(text: widget.existing?.lastName);
  late final _phone = TextEditingController(text: widget.existing?.phone);
  late final _email = TextEditingController(text: widget.existing?.email);
  late final _nationality = TextEditingController(
    text: widget.existing?.nationality,
  );
  late final _documentNumber = TextEditingController(
    text: widget.existing?.idDocumentNumber,
  );
  late IdDocumentType? _documentType = widget.existing?.idDocumentType;
  bool _busy = false;

  bool get _creation => widget.existing == null;

  /// Validateur des champs exiges a la creation seulement.
  String? _requisACreation(String? v) => _creation ? requiredText(v) : null;

  @override
  void dispose() {
    for (final c in [
      _firstName,
      _lastName,
      _phone,
      _email,
      _nationality,
      _documentNumber,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _vide(String? v) => v == null || v.trim().isEmpty ? null : v.trim();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final existing = widget.existing;
    if (existing != null) return _update(existing);

    // Filet sous les validateurs du formulaire : la regle vit dans
    // `guest_rules.dart`, et c'est elle qui decide.
    final manquants = missingForCreation(
      firstName: _firstName.text,
      lastName: _lastName.text,
      phone: _phone.text,
      documentType: _documentType,
      documentNumber: _documentNumber.text,
    );
    if (manquants.isNotEmpty) return;
    setState(() => _busy = true);

    final guest = await ref
        .read(guestRepositoryProvider)
        .create(
          firstName: _firstName.text,
          lastName: _lastName.text,
          phone: _vide(_phone.text),
          email: _vide(_email.text),
          nationality: _vide(_nationality.text),
          documentType: _documentType,
          documentNumber: _vide(_documentNumber.text),
          createdBy: ref.read(sessionProvider).agent?.id,
        );

    if (!mounted) return;
    Navigator.of(context).pop();
    montrerSucces(context, 'Fiche ${guest.code} créée.');
  }

  Future<void> _update(GuestRow existing) async {
    setState(() => _busy = true);

    final guest = await ref
        .read(guestRepositoryProvider)
        .update(
          id: existing.id,
          firstName: _firstName.text,
          lastName: _lastName.text,
          phone: _vide(_phone.text),
          email: _vide(_email.text),
          nationality: _vide(_nationality.text),
          documentType: _documentType,
          documentNumber: _vide(_documentNumber.text),
          updatedBy: ref.read(sessionProvider).agent?.id,
        );

    if (!mounted) return;
    // La fiche modifiee est rendue a l'appelant ; la page de la fiche, elle,
    // suit la base et se redessine seule.
    Navigator.of(context).pop(guest);
    montrerSucces(context, 'Fiche ${guest.code} modifiée.');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(
        _creation
            ? PhosphorIconsLight.userPlus
            : PhosphorIconsLight.identificationCard,
        size: 30,
      ),
      title: Text(_creation ? 'Nouveau client' : 'Modifier le client'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _firstName,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(labelText: 'Prénom'),
                        validator: requiredText,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _lastName,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(labelText: 'Nom'),
                        validator: requiredText,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Téléphone'),
                  validator: _requisACreation,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Courriel'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nationality,
                  decoration: const InputDecoration(labelText: 'Nationalité'),
                ),
                const SizedBox(height: 12),
                // La piece est exigee ici, dans la fiche complete. La creation
                // rapide a la reservation, elle, s'en passe : au telephone,
                // on n'a pas la piece sous les yeux.
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<IdDocumentType>(
                        initialValue: _documentType,
                        decoration: const InputDecoration(
                          labelText: 'Type de pièce',
                        ),
                        items: [
                          for (final t in IdDocumentType.values)
                            DropdownMenuItem(
                              value: t,
                              child: Text(libellePiece(t)),
                            ),
                        ],
                        onChanged: (v) => setState(() => _documentType = v),
                        validator: (v) =>
                            _creation && v == null ? champRequis : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _documentNumber,
                        decoration: const InputDecoration(labelText: 'Numéro'),
                        validator: _requisACreation,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
