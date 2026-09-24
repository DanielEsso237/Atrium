/// Creation d'une reservation (cahier des charges, F1.1).
///
/// Un ecran plein et non une boite de dialogue : il y a sept champs, un
/// calendrier et une liste de chambres, et sur une tablette de comptoir une
/// boite de dialogue de cette taille se retrouve a l'etroit des que le clavier
/// tactile monte.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formats.dart';
import '../../data/local/database.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';
import '../auth/session.dart';

final roomTypesProvider = FutureProvider<List<RoomTypeSummary>>(
  (ref) => ref.watch(databaseProvider).roomTypeSummaries(),
);

final allGuestsProvider = StreamProvider<List<GuestRow>>(
  (ref) => ref.watch(guestRepositoryProvider).watchGuests(),
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
    final today = DateTime.now();
    _dates = DateTimeRange(
      start: DateTime(today.year, today.month, today.day),
      end: DateTime(today.year, today.month, today.day + 1),
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
    final today = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 1),
      lastDate: DateTime(today.year + 2),
      initialDateRange: _dates,
      helpText: 'Dates du sejour',
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
    setState(() => _busy = true);

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
        );

    if (!mounted) return;
    context.go('/reservations');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reservation enregistree — en attente de remontee.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final guests = ref.watch(allGuestsProvider);
    final roomTypes = ref.watch(roomTypesProvider);
    final schema = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          iconSize: 28,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/reservations'),
        ),
        title: const Text('Nouvelle reservation'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Section(
                  title: 'Le client',
                  child: guests.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('Lecture impossible : $e'),
                    data: (list) => DropdownButtonFormField<String>(
                      initialValue: _guestId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Client',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      items: [
                        for (final g in list)
                          DropdownMenuItem(
                            value: g.id,
                            child: Text(
                              '${g.lastName.toUpperCase()} ${g.firstName}'
                              '  ·  ${g.code}',
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _guestId = v),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                _Section(
                  title: 'Le sejour',
                  child: Column(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _pickDates,
                        icon: const Icon(Icons.date_range),
                        label: Text(
                          _dates == null
                              ? 'Choisir les dates'
                              : '${formatShortDate(_dates!.start)}  →  '
                                    '${formatShortDate(_dates!.end)}'
                                    '   ·   $_nights nuit'
                                    '${_nights > 1 ? 's' : ''}',
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                      const SizedBox(height: 16),
                      roomTypes.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => Text('Lecture impossible : $e'),
                        data: (types) =>
                            DropdownButtonFormField<RoomTypeSummary>(
                              initialValue: _roomType,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Categorie',
                                prefixIcon: Icon(Icons.bed_outlined),
                              ),
                              items: [
                                for (final t in types)
                                  DropdownMenuItem(
                                    value: t,
                                    child: Text(
                                      '${t.label}  ·  ${formatAmount(t.rate)}'
                                      '  ·  ${t.roomCount} chambres',
                                    ),
                                  ),
                              ],
                              onChanged: (v) => setState(() {
                                _roomType = v;
                                _rateOverride = null;
                                _roomId = null;
                              }),
                            ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _Counter(
                              label: 'Adultes',
                              value: _adults,
                              min: 1,
                              onChange: (v) => setState(() => _adults = v),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _Counter(
                              label: 'Enfants',
                              value: _children,
                              min: 0,
                              onChange: (v) => setState(() => _children = v),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                if (_roomType != null && _dates != null)
                  _AvailableRooms(
                    roomTypeId: _roomType!.typeId,
                    range: _dates!,
                    selected: _roomId,
                    onSelect: (id) => setState(() => _roomId = id),
                  ),
                const SizedBox(height: 16),

                _Section(
                  title: 'Le tarif',
                  child: Column(
                    children: [
                      TextFormField(
                        initialValue: _rate == 0 ? '' : '$_rate',
                        key: ValueKey('rate-${_roomType?.typeId}'),
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Tarif par nuit (FCFA)',
                          prefixIcon: const Icon(Icons.payments_outlined),
                          helperText: _roomType == null
                              ? 'Choisir une categorie'
                              : 'Tarif de reference : '
                                    '${formatAmount(_roomType!.rate)}',
                        ),
                        onChanged: (v) =>
                            setState(() => _rateOverride = int.tryParse(v)),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: schema.primaryContainer.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Text(
                              'Total estime',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              formatAmount(_total),
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                _Section(
                  title: 'Notes',
                  child: TextField(
                    controller: _notes,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Demandes particulieres, remarques internes…',
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                FilledButton.icon(
                  onPressed: (_canSave && !_busy) ? _save : null,
                  icon: const Icon(Icons.check),
                  label: const Text('Enregistrer la reservation'),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
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
    final schema = Theme.of(context).colorScheme;

    return _Section(
      title: 'La chambre (facultatif)',
      child: FutureBuilder<List<AvailableRoom>>(
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
            return Text(
              'Aucune chambre libre de cette categorie sur la periode. '
              'La reservation peut quand meme etre prise : la chambre sera '
              'attribuee plus tard.',
              style: TextStyle(fontSize: 16, color: schema.error),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${rooms.length} chambre${rooms.length > 1 ? 's' : ''} '
                'libre${rooms.length > 1 ? 's' : ''} sur la periode. '
                'Laisser vide pour attribuer plus tard.',
                style: TextStyle(fontSize: 15, color: schema.outline),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final room in rooms)
                    ChoiceChip(
                      label: Text(
                        room.number,
                        style: const TextStyle(fontSize: 18),
                      ),
                      selected: selected == room.id,
                      onSelected: (on) => onSelect(on ? room.id : null),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({
    required this.label,
    required this.value,
    required this.min,
    required this.onChange,
  });

  final String label;
  final int value;
  final int min;
  final void Function(int) onChange;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: schema.outline),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 17)),
          const Spacer(),
          IconButton(
            iconSize: 28,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: value > min ? () => onChange(value - 1) : null,
          ),
          SizedBox(
            width: 36,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            iconSize: 28,
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => onChange(value + 1),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );
}
