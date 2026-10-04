/// Creation d'une reservation (cahier des charges, F1.1).
///
/// Un ecran plein et non une boite de dialogue : il y a sept champs, un
/// calendrier et une liste de chambres, et sur une tablette de comptoir une
/// boite de dialogue de cette taille se retrouve a l'etroit des que le clavier
/// tactile monte.
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
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';
import '../administration/deposit_section.dart' show formatRate;
import '../auth/session.dart';
import '../guests/guest_picker.dart';
import 'deposit_dialog.dart';

final roomTypesProvider = FutureProvider<List<RoomTypeSummary>>(
  (ref) => ref.watch(databaseProvider).roomTypeSummaries(),
);

class NewReservationScreen extends ConsumerStatefulWidget {
  const NewReservationScreen({super.key, this.guestId});

  /// Pre-selection du client, quand on arrive depuis sa fiche.
  final String? guestId;

  @override
  ConsumerState<NewReservationScreen> createState() =>
      _NewReservationScreenState();
}

class _NewReservationScreenState extends ConsumerState<NewReservationScreen> {
  String? _guestId;
  RoomTypeSummary? _roomType;
  DateTimeRange? _dates;
  int _adults = 1;
  int _children = 0;
  int? _rateOverride;
  String? _roomId;
  bool _busy = false;

  final _notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    _guestId = widget.guestId;

    // La journee hoteliere, pas la date du calendrier. Un client qui se
    // presente a deux heures du matin arrive dans la journee de la veille :
    // c'est cette nuit-la qu'il occupe, et c'est sur cette journee que la
    // reception compte ses arrivees. Proposer le lendemain par defaut faisait
    // disparaitre la reservation du tableau de bord au moment meme ou on la
    // creait.
    final today = businessDayFor(DateTime.now());
    _dates = DateTimeRange(
      start: today,
      end: today.add(const Duration(days: 1)),
    );
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  int get _nights =>
      _dates == null ? 0 : _dates!.end.difference(_dates!.start).inDays;

  /// Le tarif applique : celui saisi, sinon celui de la categorie.
  ///
  /// La categorie porte le prix, jamais la chambre : revaloriser la gamme VIP
  /// doit se faire en une seule ecriture, pas chambre par chambre.
  int get _rate => _rateOverride ?? _roomType?.rate ?? 0;

  int get _total => _rate * (_nights < 1 ? 1 : _nights);

  bool get _canSave =>
      _guestId != null && _roomType != null && _dates != null && _nights > 0;

  Future<void> _pickDates() async {
    final today = businessDayFor(DateTime.now());
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 1),
      lastDate: DateTime(today.year + 2),
      initialDateRange: _dates,
      helpText: 'Dates du séjour',
      saveText: 'Valider',
    );
    if (range != null) {
      setState(() {
        _dates = range;
        // Les chambres libres dependent de la periode : une chambre choisie
        // pour d'autres dates n'a plus de raison de rester selectionnee.
        _roomId = null;
      });
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;

    // Les arrhes que la regle de l'hotel demande : la reception les encaisse
    // tout de suite, ou les laisse dues.
    final regle = await ref.read(settingsRepositoryProvider).depositRule();
    final du = regle?.depositFor(_total) ?? 0;
    DepositChoice? choix;
    if (du > 0) {
      if (!mounted) return;
      choix = await askDeposit(
        context,
        du: du,
        total: _total,
        regle: regle!.isFixed
            ? 'Somme fixe de ${formatAmount(regle.amount!)}'
            : formatRate(regle.rateBp!),
      );
      if (choix == null) return;
    }
    setState(() => _busy = true);

    try {
      await ref
          .read(reservationRepositoryProvider)
          .create(
            guestId: _guestId!,
            roomTypeId: _roomType!.typeId,
            arrival: _dates!.start,
            departure: _dates!.end,
            nightlyRate: _rate,
            adults: _adults,
            children: _children,
            roomId: _roomId,
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            createdBy: ref.read(sessionProvider).agent?.id,
            depositCollected: choix?.montant,
            depositMethod: choix?.moyen,
          );
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    if (!mounted) return;
    context.go('/reservations');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Réservation enregistrée, elle remonte au serveur.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roomTypes = ref.watch(roomTypesProvider);
    final largeur = MediaQuery.sizeOf(context).width;
    final etroit = largeur < 600;
    final marge = etroit ? 18.0 : 32.0;

    final etapes = <Widget>[
      _Etape(
        numero: 1,
        titre: 'Le client',
        fait: _guestId != null,
        child: GuestPicker(
          selectedId: _guestId,
          onSelected: (id) => setState(() => _guestId = id),
        ),
      ),
      _Etape(
        numero: 2,
        titre: 'Le séjour',
        fait: _nights > 0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Dates(dates: _dates, nuits: _nights, onTap: _pickDates),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, c) {
                final adultes = _Compteur(
                  label: 'Adultes',
                  icone: PhosphorIconsLight.user,
                  value: _adults,
                  min: 1,
                  onChange: (v) => setState(() => _adults = v),
                );
                final enfants = _Compteur(
                  label: 'Enfants',
                  icone: PhosphorIconsLight.baby,
                  value: _children,
                  min: 0,
                  onChange: (v) => setState(() => _children = v),
                );
                return c.maxWidth < 420
                    ? Column(
                        children: [
                          adultes,
                          const SizedBox(height: 10),
                          enfants,
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: adultes),
                          const SizedBox(width: 12),
                          Expanded(child: enfants),
                        ],
                      );
              },
            ),
          ],
        ),
      ),
      _Etape(
        numero: 3,
        titre: 'La catégorie',
        fait: _roomType != null,
        child: roomTypes.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('Lecture impossible : $e'),
          data: (types) => Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final t in types)
                _CarteCategorie(
                  type: t,
                  choisie: _roomType?.typeId == t.typeId,
                  onTap: () => setState(() {
                    _roomType = t;
                    _rateOverride = null;
                    _roomId = null;
                  }),
                ),
            ],
          ),
        ),
      ),
      if (_roomType != null && _dates != null)
        _Etape(
          numero: 4,
          titre: 'La chambre',
          facultatif: true,
          fait: _roomId != null,
          child: _AvailableRooms(
            roomTypeId: _roomType!.typeId,
            range: _dates!,
            selected: _roomId,
            onSelect: (id) => setState(() => _roomId = id),
          ),
        ),
      _Etape(
        numero: _roomType != null ? 5 : 4,
        titre: 'Tarif et notes',
        fait: _rate > 0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              initialValue: _rate == 0 ? '' : '$_rate',
              key: ValueKey('rate-${_roomType?.typeId}'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Tarif par nuit (FCFA)',
                prefixIcon: const Icon(PhosphorIconsLight.tag, size: 22),
                helperText: _roomType == null
                    ? "Choisissez d'abord une catégorie"
                    : 'Tarif de référence : ${formatAmount(_roomType!.rate)}',
              ),
              onChanged: (v) => setState(() => _rateOverride = int.tryParse(v)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _notes,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Notes',
                alignLabelWithHint: true,
                hintText: 'Demandes particulières, remarques internes…',
              ),
            ),
          ],
        ),
      ),
    ];

    final ticket = _Ticket(
      guestId: _guestId,
      dates: _dates,
      nuits: _nights,
      adultes: _adults,
      enfants: _children,
      categorie: _roomType?.label,
      chambreId: _roomId,
      tarif: _rate,
      total: _total,
      peutEnregistrer: _canSave && !_busy,
      occupe: _busy,
      onEnregistrer: _save,
    );

    final formulaire = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < etapes.length; i++)
          FadeUp(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: etapes[i],
            ),
          ),
      ],
    );

    return ModuleScaffold(
      title: 'Nouvelle réservation',
      subtitle:
          'Un client, des dates, une catégorie : la chambre peut attendre.',
      action: etroit
          ? null
          : PillButton(
              label: 'Retour aux réservations',
              icon: PhosphorIconsLight.arrowLeft,
              tone: PillTone.quiet,
              onPressed: () => context.go('/reservations'),
            ),
      body: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth >= 940) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(marge, 4, 20, 40),
                    child: formulaire,
                  ),
                ),
                SizedBox(
                  width: 360,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(0, 4, marge, 32),
                    child: FadeUp(index: 1, child: ticket),
                  ),
                ),
              ],
            );
          }
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(marge, 4, marge, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [formulaire, ticket],
            ),
          );
        },
      ),
    );
  }
}

/// Une etape du formulaire : son numero dans une pastille, qui se coche une
/// fois l'etape remplie. On voit d'un coup d'oeil ce qui manque.
class _Etape extends StatelessWidget {
  const _Etape({
    required this.numero,
    required this.titre,
    required this.fait,
    required this.child,
    this.facultatif = false,
  });

  final int numero;
  final String titre;
  final bool fait;
  final bool facultatif;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 420));
    return Bezel(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: duree,
                curve: atriumSpring,
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: fait ? p.accent : p.surfaceMuted,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: AnimatedSwitcher(
                  duration: duree,
                  child: fait
                      ? Icon(
                          PhosphorIconsFill.check,
                          key: const ValueKey('ok'),
                          size: 17,
                          color: p.onAccent,
                        )
                      : Text(
                          '$numero',
                          key: const ValueKey('n'),
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: p.textSecondary,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                titre,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  color: p.text,
                ),
              ),
              if (facultatif) ...[
                const SizedBox(width: 10),
                const Tag('Facultatif'),
              ],
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

/// Les dates du sejour : arrivee et depart en deux blocs, les nuits entre.
class _Dates extends StatelessWidget {
  const _Dates({required this.dates, required this.nuits, required this.onTap});

  final DateTimeRange? dates;
  final int nuits;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    Widget bloc(String libelle, DateTime? d) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            libelle,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            d == null ? '—' : formatDayMonth(d),
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
              color: p.text,
            ),
          ),
          Text(
            d == null ? '' : formatWeekdayShort(d),
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 13,
              color: p.textSecondary,
            ),
          ),
        ],
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: HoverRow(
        onTap: onTap,
        radius: 20,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            bloc('Arrivée', dates?.start),
            Column(
              children: [
                Icon(PhosphorIconsLight.moonStars, size: 20, color: p.accent),
                const SizedBox(height: 4),
                Text(
                  '$nuits nuit${nuits > 1 ? 's' : ''}',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 24),
            bloc('Départ', dates?.end),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: p.surfaceMuted,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                PhosphorIconsLight.calendarDots,
                size: 22,
                color: p.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Une categorie a choisir : une carte, pas une ligne de menu deroulant. On
/// compare les prix sans ouvrir quoi que ce soit.
class _CarteCategorie extends StatelessWidget {
  const _CarteCategorie({
    required this.type,
    required this.choisie,
    required this.onTap,
  });

  final RoomTypeSummary type;
  final bool choisie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 380));
    return Semantics(
      button: true,
      selected: choisie,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: duree,
            curve: atriumSpring,
            width: 176,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: choisie ? p.accent.withValues(alpha: 0.12) : p.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: choisie ? p.accent : p.border,
                width: choisie ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        type.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: p.text,
                        ),
                      ),
                    ),
                    Icon(
                      choisie
                          ? PhosphorIconsFill.checkCircle
                          : PhosphorIconsLight.circle,
                      size: 20,
                      color: choisie ? p.accent : p.placeholder,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  formatAmount(type.rate),
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: p.text,
                    fontFeatures: tabularFigures,
                  ),
                ),
                Text(
                  'par nuit · ${type.roomCount} chambre${type.roomCount > 1 ? 's' : ''}',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12.5,
                    color: p.textSecondary,
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

/// Le recapitulatif, comme un ticket : ce qui sera enregistre, et le bouton
/// pour le faire. Il se remplit a mesure qu'on avance.
class _Ticket extends ConsumerWidget {
  const _Ticket({
    required this.guestId,
    required this.dates,
    required this.nuits,
    required this.adultes,
    required this.enfants,
    required this.categorie,
    required this.chambreId,
    required this.tarif,
    required this.total,
    required this.peutEnregistrer,
    required this.occupe,
    required this.onEnregistrer,
  });

  final String? guestId;
  final DateTimeRange? dates;
  final int nuits;
  final int adultes;
  final int enfants;
  final String? categorie;
  final String? chambreId;
  final int tarif;
  final int total;
  final bool peutEnregistrer;
  final bool occupe;
  final VoidCallback onEnregistrer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final doux = p.onHeroSoft;
    Widget ligne(IconData icone, String libelle, String? valeur) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icone, size: 18, color: doux),
          const SizedBox(width: 10),
          Text(
            libelle,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 14,
              color: doux,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              valeur ?? '—',
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: valeur == null ? doux : p.onHero,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
        ],
      ),
    );

    return Bezel(
      core: p.hero,
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'RÉCAPITULATIF',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.6,
              color: doux,
            ),
          ),
          const SizedBox(height: 14),
          FutureBuilder(
            key: ValueKey(guestId),
            future: guestId == null
                ? null
                : ref.read(guestRepositoryProvider).byId(guestId!),
            builder: (context, snap) {
              final g = snap.data;
              return ligne(
                PhosphorIconsLight.user,
                'Client',
                g == null ? null : '${g.firstName} ${g.lastName}'.trim(),
              );
            },
          ),
          ligne(
            PhosphorIconsLight.calendarBlank,
            'Séjour',
            dates == null
                ? null
                : '${formatDayMonth(dates!.start)} → ${formatDayMonth(dates!.end)}',
          ),
          ligne(
            PhosphorIconsLight.usersThree,
            'Personnes',
            '$adultes adulte${adultes > 1 ? 's' : ''}'
                '${enfants > 0 ? ', $enfants enfant${enfants > 1 ? 's' : ''}' : ''}',
          ),
          ligne(PhosphorIconsLight.bed, 'Catégorie', categorie),
          ligne(
            PhosphorIconsLight.door,
            'Chambre',
            chambreId == null ? 'attribuée plus tard' : 'choisie',
          ),
          ligne(
            PhosphorIconsLight.tag,
            'Tarif',
            tarif == 0 ? null : '${formatAmount(tarif)} / nuit',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Container(
              height: 1,
              color: p.onHero.withValues(alpha: 0.14),
            ),
          ),
          Text(
            'Total estimé · $nuits nuit${nuits > 1 ? 's' : ''}',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 13.5,
              color: doux,
            ),
          ),
          const SizedBox(height: 4),
          TweenAnimationBuilder<double>(
            tween: Tween(end: total.toDouble()),
            duration: AtriumMotion.of(
              context,
              const Duration(milliseconds: 600),
            ),
            curve: atriumSpring,
            builder: (_, v, _) => Text(
              formatAmount(v.round()),
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.2,
                color: p.heroAccent,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          const SizedBox(height: 18),
          PillButton(
            label: occupe ? 'Enregistrement…' : 'Enregistrer la réservation',
            icon: PhosphorIconsLight.check,
            tone: PillTone.accent,
            expand: true,
            onPressed: peutEnregistrer ? onEnregistrer : null,
          ),
          if (!peutEnregistrer && !occupe) ...[
            const SizedBox(height: 10),
            Text(
              'Il faut un client, des dates et une catégorie.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13,
                color: doux,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AvailableRooms extends ConsumerWidget {
  const _AvailableRooms({
    required this.roomTypeId,
    required this.range,
    required this.selected,
    required this.onSelect,
  });

  final String roomTypeId;
  final DateTimeRange range;
  final String? selected;
  final void Function(String?) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    return FutureBuilder<List<AvailableRoom>>(
      future: ref
          .read(reservationRepositoryProvider)
          .availableRooms(
            roomTypeId: roomTypeId,
            arrival: range.start,
            departure: range.end,
          ),
      builder: (context, snap) {
        if (!snap.hasData) return const LinearProgressIndicator();
        final rooms = snap.data!;

        if (rooms.isEmpty) {
          return Row(
            children: [
              Icon(PhosphorIconsLight.warningCircle, color: p.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Aucune chambre libre de cette catégorie sur la période. '
                  'La réservation peut quand même être prise : la chambre '
                  'sera attribuée plus tard.',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 14.5,
                    color: p.text,
                  ),
                ),
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${rooms.length} chambre${rooms.length > 1 ? 's' : ''} '
              'libre${rooms.length > 1 ? 's' : ''} sur la période. '
              'Laisser vide pour attribuer plus tard.',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 14,
                color: p.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final room in rooms)
                  RoomChoiceTile(
                    numero: room.number,
                    choisie: selected == room.id,
                    onTap: () => onSelect(selected == room.id ? null : room.id),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Compteur extends StatelessWidget {
  const _Compteur({
    required this.label,
    required this.icone,
    required this.value,
    required this.min,
    required this.onChange,
  });

  final String label;
  final IconData icone;
  final int value;
  final int min;
  final void Function(int) onChange;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    Widget bouton(IconData i, VoidCallback? f, String tip) => IconButton(
      tooltip: tip,
      onPressed: f,
      style: IconButton.styleFrom(
        backgroundColor: p.surfaceMuted,
        disabledBackgroundColor: p.surfaceMuted.withValues(alpha: 0.4),
        fixedSize: const Size(44, 44),
      ),
      icon: Icon(i, size: 20),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Icon(icone, size: 20, color: p.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
          ),
          bouton(
            PhosphorIconsLight.minus,
            value > min ? () => onChange(value - 1) : null,
            'Moins',
          ),
          SizedBox(
            width: 40,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: p.text,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          bouton(PhosphorIconsLight.plus, () => onChange(value + 1), 'Plus'),
        ],
      ),
    );
  }
}
