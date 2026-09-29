/// Fichier clients (cahier des charges, F1.6).
///
/// Liste, recherche, creation, fiche et historique des sejours.
///
/// C'est le premier ecran ou la reception **ecrit**. La fiche part dans Drift
/// et dans la file d'attente en une seule transaction, sans attendre le
/// reseau : le client est enregistre meme si le Wi-Fi est tombe.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formats.dart';
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

final guestsProvider = StreamProvider<List<GuestRow>>((ref) {
  final search = ref.watch(guestSearchProvider);
  return ref.watch(guestRepositoryProvider).watchGuests(search: search);
});

/// Le client affiche dans le panneau de droite, sur tablette et PC.
class _ClientChoisi extends Notifier<GuestRow?> {
  @override
  GuestRow? build() => null;

  void choisir(GuestRow? g) => state = g;
}

final _clientChoisiProvider = NotifierProvider<_ClientChoisi, GuestRow?>(
  _ClientChoisi.new,
);

String libellePiece(IdDocumentType t) => switch (t) {
  IdDocumentType.ID_CARD => "Carte d'identité",
  IdDocumentType.PASSPORT => 'Passeport',
  IdDocumentType.DRIVING_LICENSE => 'Permis de conduire',
  IdDocumentType.RESIDENCE_PERMIT => 'Titre de séjour',
  IdDocumentType.OTHER => 'Autre pièce',
};

class GuestsScreen extends ConsumerWidget {
  const GuestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guests = ref.watch(guestsProvider);
    final recherche = ref.watch(guestSearchProvider).trim();
    final nombre = guests.value?.length;
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    void nouveau() => showDialog<void>(
      context: context,
      builder: (_) => const _GuestFormDialog(),
    );

    return ModuleScaffold(
      title: 'Clients',
      subtitle: nombre == null
          ? null
          : recherche.isEmpty
          ? '$nombre fiche${nombre > 1 ? 's' : ''} au fichier'
          : '$nombre résultat${nombre > 1 ? 's' : ''} pour « $recherche »',
      action: PillButton(
        label: 'Nouveau client',
        icon: PhosphorIconsLight.userPlus,
        tone: PillTone.accent,
        onPressed: nouveau,
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final large = c.maxWidth >= 900;
          final liste = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(marge, 0, large ? 0 : marge, 12),
                child: SearchPill(
                  hint: 'Nom, téléphone, code client…',
                  onChanged: (v) =>
                      ref.read(guestSearchProvider.notifier).update(v),
                ),
              ),
              Expanded(
                child: guests.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => EmptyState(
                    icon: PhosphorIconsLight.warningCircle,
                    title: 'Lecture impossible',
                    message: '$e',
                  ),
                  data: (list) => list.isEmpty
                      ? EmptyState(
                          icon: recherche.isEmpty
                              ? PhosphorIconsLight.addressBook
                              : PhosphorIconsLight.magnifyingGlass,
                          title: recherche.isEmpty
                              ? 'Fichier vide'
                              : 'Aucun client ne correspond',
                          message: recherche.isEmpty
                              ? 'Les fiches se créent ici ou à la volée '
                                    'depuis une réservation.'
                              : 'Vérifiez l’orthographe, ou créez la fiche.',
                          action: PillButton(
                            label: 'Nouveau client',
                            icon: PhosphorIconsLight.userPlus,
                            tone: PillTone.quiet,
                            onPressed: nouveau,
                          ),
                        )
                      : _Liste(
                          clients: list,
                          large: large,
                          padding: EdgeInsets.fromLTRB(
                            marge,
                            0,
                            large ? 0 : marge,
                            32,
                          ),
                        ),
                ),
              ),
            ],
          );
          if (!large) return liste;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 400, child: liste),
              const SizedBox(width: 18),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(0, 0, marge, 24),
                  child: const _PanneauClient(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// La liste, rangee par initiale du nom.
class _Liste extends ConsumerWidget {
  const _Liste({
    required this.clients,
    required this.large,
    required this.padding,
  });

  final List<GuestRow> clients;
  final bool large;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choisi = ref.watch(_clientChoisiProvider);
    final lettres = <String, List<GuestRow>>{};
    for (final g in clients) {
      final l = g.lastName.isEmpty ? '#' : g.lastName[0].toUpperCase();
      lettres.putIfAbsent(l, () => []).add(g);
    }
    final cles = lettres.keys.toList()..sort();
    return ListView.builder(
      padding: padding,
      itemCount: cles.length,
      itemBuilder: (context, i) {
        final groupe = lettres[cles[i]]!;
        return FadeUp(
          index: i.clamp(0, 6),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 8),
                  child: Eyebrow(cles[i]),
                ),
                Bezel(
                  radius: 24,
                  padding: const EdgeInsets.all(5),
                  child: Column(
                    children: [
                      for (final g in groupe)
                        _LigneClient(
                          guest: g,
                          choisi: large && choisi?.id == g.id,
                          onTap: () {
                            if (large) {
                              ref
                                  .read(_clientChoisiProvider.notifier)
                                  .choisir(g);
                            } else {
                              showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                showDragHandle: false,
                                builder: (_) => FractionallySizedBox(
                                  heightFactor: 0.9,
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(30),
                                    ),
                                    child: Material(
                                      color: AtriumColors.background,
                                      child: _FicheClient(
                                        guest: g,
                                        fermable: true,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LigneClient extends StatelessWidget {
  const _LigneClient({
    required this.guest,
    required this.choisi,
    required this.onTap,
  });

  final GuestRow guest;
  final bool choisi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return AnimatedContainer(
      duration: AtriumMotion.of(context, const Duration(milliseconds: 300)),
      curve: atriumSpring,
      decoration: BoxDecoration(
        color: choisi ? p.accent.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
      ),
      child: HoverRow(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Monogram('${guest.firstName} ${guest.lastName}', size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${guest.lastName.toUpperCase()} ${guest.firstName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                  Text(
                    [
                      guest.code,
                      if (guest.phone != null) guest.phone!,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13,
                      color: p.textSecondary,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                ],
              ),
            ),
            // Une fiche creee hors ligne se signale : la reception doit
            // savoir ce qui est deja connu du serveur et ce qui ne l'est pas
            // encore.
            if (guest.syncState == SyncState.pending)
              Tooltip(
                message: 'En attente de remontée au serveur',
                child: Icon(
                  PhosphorIconsLight.cloudArrowUp,
                  size: 20,
                  color: p.accent,
                ),
              )
            else
              Icon(
                PhosphorIconsLight.caretRight,
                size: 18,
                color: choisi ? p.accent : p.textSecondary,
              ),
          ],
        ),
      ),
    );
  }
}

/// Le panneau de droite : la fiche du client choisi, ou une invitation.
class _PanneauClient extends ConsumerWidget {
  const _PanneauClient();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choisi = ref.watch(_clientChoisiProvider);
    return Bezel(
      radius: 30,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AnimatedSwitcher(
          duration: AtriumMotion.of(context, const Duration(milliseconds: 380)),
          switchInCurve: atriumSpring,
          child: choisi == null
              ? const EmptyState(
                  key: ValueKey('vide'),
                  icon: PhosphorIconsLight.identificationCard,
                  title: 'Choisissez un client',
                  message:
                      'Sa fiche, ses pièces et ses séjours s’affichent ici.',
                )
              : _FicheClient(
                  key: ValueKey(choisi.id),
                  guest: choisi,
                  fermable: false,
                ),
        ),
      ),
    );
  }
}

class _FicheClient extends ConsumerWidget {
  const _FicheClient({super.key, required this.guest, required this.fermable});

  final GuestRow guest;
  final bool fermable;

  /// Ouvre le formulaire de modification sur cette fiche.
  ///
  /// Sur telephone, la fiche est une feuille : elle se ferme d'abord, et le
  /// formulaire s'ouvre depuis le navigateur, qui lui survit -- son propre
  /// contexte meurt avec elle. Sur tablette, c'est un panneau fixe : il reste,
  /// et on lui donne la fiche modifiee pour qu'il ne montre pas l'ancienne.
  Future<void> _modifier(BuildContext context, WidgetRef ref) async {
    final navigator = Navigator.of(context);
    if (fermable) navigator.pop();
    final modifie = await showDialog<GuestRow>(
      context: navigator.context,
      builder: (_) => _GuestFormDialog(existing: guest),
    );
    if (modifie != null && !fermable) {
      ref.read(_clientChoisiProvider.notifier).choisir(modifie);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(guestRepositoryProvider);
    final p = AtriumPalette.current;
    final nom = '${guest.firstName} ${guest.lastName}'.trim();

    Widget info(IconData icone, String cle, String? valeur) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: p.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icone, size: 19, color: p.text),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(cle, style: _styleCle),
                Text(
                  valeur ?? 'Non renseigné',
                  style: _styleValeur.copyWith(
                    color: valeur == null ? p.placeholder : p.text,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // L'en-tete : l'initiale en grand sur la nuit.
        Container(
          padding: const EdgeInsets.fromLTRB(24, 22, 16, 24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [p.heroTop, p.hero],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Monogram(nom, size: 64),
                  const Spacer(),
                  if (fermable)
                    IconButton(
                      tooltip: 'Fermer',
                      style: IconButton.styleFrom(
                        backgroundColor: p.onHero.withValues(alpha: 0.1),
                      ),
                      icon: Icon(PhosphorIconsLight.x, color: p.onHero),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '${guest.firstName} ${guest.lastName.toUpperCase()}',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                  color: p.onHero,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                guest.code,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.onHeroSoft,
                  fontFeatures: tabularFigures,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  PillButton(
                    label: 'Réserver pour ce client',
                    icon: PhosphorIconsLight.calendarPlus,
                    tone: PillTone.accent,
                    compact: true,
                    onPressed: () {
                      if (fermable) Navigator.of(context).pop();
                      context.go('/reservations/nouvelle?client=${guest.id}');
                    },
                  ),
                  PillButton(
                    label: 'Modifier',
                    icon: PhosphorIconsLight.identificationCard,
                    tone: PillTone.quiet,
                    compact: true,
                    onPressed: () => _modifier(context, ref),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Eyebrow('Coordonnées et identité'),
              const SizedBox(height: 6),
              info(PhosphorIconsLight.phone, 'Téléphone', guest.phone),
              info(PhosphorIconsLight.envelopeSimple, 'Courriel', guest.email),
              info(PhosphorIconsLight.globe, 'Nationalité', guest.nationality),
              info(
                PhosphorIconsLight.identificationCard,
                "Pièce d'identité",
                guest.idDocumentNumber == null
                    ? null
                    : '${guest.idDocumentType == null ? '' : '${libellePiece(guest.idDocumentType!)} '}'
                          '${guest.idDocumentNumber}',
              ),
              const SizedBox(height: 18),
              FutureBuilder<List<GuestStay>>(
                future: repo.stays(guest.id),
                builder: (context, snap) {
                  final stays = snap.data ?? const <GuestStay>[];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Eyebrow(
                        'Séjours',
                        trailing: Text(
                          '${stays.length}',
                          style: _styleCle.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (stays.isEmpty)
                        Text('Aucun séjour enregistré.', style: _styleCle)
                      else
                        for (final s in stays) _LigneSejour(sejour: s),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }
}

class _LigneSejour extends StatelessWidget {
  const _LigneSejour({required this.sejour});

  final GuestStay sejour;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final a = parseIsoDate(sejour.arrival);
    final d = parseIsoDate(sejour.departure);
    final (String libelle, Color couleur) = switch (sejour.status) {
      'CHECKED_IN' => ('En cours', const Color(0xFF12A876)),
      'CHECKED_OUT' => ('Terminé', const Color(0xFF6B7391)),
      'CANCELLED' => ('Annulé', const Color(0xFFE5484D)),
      'NO_SHOW' => ('Non présenté', const Color(0xFFE5484D)),
      'CONFIRMED' => ('Confirmé', const Color(0xFF3F7BF2)),
      _ => ('En attente', const Color(0xFFF2A20C)),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${a == null ? sejour.arrival : formatDayMonth(a)} → '
                  '${d == null ? sejour.departure : formatDayMonth(d)}'
                  '${a == null ? '' : ' ${a.year}'}',
                  style: _styleValeur,
                ),
                Text(sejour.reference, style: _styleCle),
              ],
            ),
          ),
          Tag(libelle, color: couleur),
        ],
      ),
    );
  }
}

TextStyle get _styleCle => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 12.5,
  fontWeight: FontWeight.w500,
  color: AtriumColors.textSecondary,
  fontFeatures: tabularFigures,
);

TextStyle get _styleValeur => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 15,
  fontWeight: FontWeight.w600,
  color: AtriumColors.textPrimary,
  fontFeatures: tabularFigures,
);

/// Creer une fiche, ou modifier celle qu'on lui passe.
///
/// Un seul formulaire pour les deux, mais pas les memes exigences : a la
/// creation, les regles de `guest_rules.dart` ; a la modification, nom et
/// prenom seulement. Un client ancien sans telephone ni piece doit pouvoir
/// etre corrige tel quel -- l'obliger a tout remplir le rendrait intouchable
/// le jour ou il n'a pas ses papiers.
class _GuestFormDialog extends ConsumerStatefulWidget {
  const _GuestFormDialog({this.existing});

  final GuestRow? existing;

  @override
  ConsumerState<_GuestFormDialog> createState() => _GuestFormDialogState();
}

class _GuestFormDialogState extends ConsumerState<_GuestFormDialog> {
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Fiche ${guest.code} créée, elle remonte au serveur.'),
      ),
    );
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
    // La fiche modifiee est rendue a l'appelant : le panneau lateral garde
    // sinon l'ancienne version sous les yeux.
    Navigator.of(context).pop(guest);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Fiche ${guest.code} modifiée, elle remonte au serveur.'),
      ),
    );
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
