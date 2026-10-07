import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/queries/rooms_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

/// Propose les chambres libres puis lance le menage de la selection.
Future<void> showRoomCleaningDialog(BuildContext context) async {
  final count = await showDialog<int>(
    context: context,
    builder: (_) => const _RoomCleaningDialog(),
  );
  if (count == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Ménage lancé pour $count chambre${count > 1 ? 's' : ''}.'),
    ),
  );
}

class _RoomCleaningDialog extends ConsumerStatefulWidget {
  const _RoomCleaningDialog();

  @override
  ConsumerState<_RoomCleaningDialog> createState() =>
      _RoomCleaningDialogState();
}

class _RoomCleaningDialogState extends ConsumerState<_RoomCleaningDialog> {
  final _selected = <String>{};
  bool _busy = false;
  String? _error;

  Future<void> _start(Set<String> ids) async {
    if (_busy || ids.isEmpty) return;
    final session = ref.read(sessionProvider);
    if (session.agent == null || !session.acces.peut('housekeeping.manage')) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final count = await ref
          .read(housekeepingRepositoryProvider)
          .startVacantRooms(ids, by: session.agent!.id);
      if (mounted) Navigator.of(context).pop(count);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Exception {
      if (mounted) {
        setState(() => _error = 'Le ménage n’a pas pu être lancé. Réessayez.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final rooms = ref.watch(vacantRoomsForCleaningProvider);
    final liste = rooms.value ?? const <RoomBoardEntry>[];
    final available = liste.map((r) => r.roomId).toSet();
    final selected = _selected.intersection(available);
    final peutGerer = ref
        .watch(sessionProvider)
        .acces
        .peut('housekeeping.manage');
    final size = MediaQuery.sizeOf(context);

    return PopScope(
      canPop: !_busy,
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        backgroundColor: p.paper,
        child: SizedBox(
          width: math.min(600, size.width - 32),
          height: math.min(660, size.height - 64),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Ménage d’une chambre',
                              style: atriumDisplay(28),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Sélectionnez une ou plusieurs chambres libres.',
                              style: TextStyle(
                                color: p.textSecondary,
                                fontSize: 14,
                              ),
                            ),
                            if (liste.isNotEmpty)
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: const Text('Tout sélectionner'),
                                tristate: true,
                                value: selected.isEmpty
                                    ? false
                                    : selected.length == liste.length
                                    ? true
                                    : null,
                                onChanged: _busy || !peutGerer
                                    ? null
                                    : (_) => setState(() {
                                        if (selected.length == liste.length) {
                                          _selected.clear();
                                        } else {
                                          _selected.addAll(available);
                                        }
                                      }),
                              ),
                            const Divider(height: 1),
                          ],
                        ),
                      ),
                      rooms.when(
                        loading: () => const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        error: (error, _) => const SliverToBoxAdapter(
                          child: EmptyState(
                            icon: PhosphorIconsLight.warningCircle,
                            title: 'Lecture impossible',
                            message: 'Fermez cette fenêtre puis réessayez.',
                          ),
                        ),
                        data: (liste) => liste.isEmpty
                            ? const SliverToBoxAdapter(
                                child: EmptyState(
                                  icon: PhosphorIconsLight.broom,
                                  title: 'Aucune chambre libre',
                                  message:
                                      'Les chambres libres à nettoyer apparaîtront ici.',
                                ),
                              )
                            : SliverList.builder(
                                itemCount: liste.length,
                                itemBuilder: (context, index) {
                                  final room = liste[index];
                                  return CheckboxListTile(
                                    key: ValueKey('clean-room-${room.roomId}'),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    selected: selected.contains(room.roomId),
                                    selectedTileColor: p.accentTint,
                                    value: selected.contains(room.roomId),
                                    title: Text(
                                      'Chambre ${room.number}',
                                      style: TextStyle(
                                        color: p.text,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    subtitle: Text(
                                      [
                                        room.typeLabel,
                                        if (room.floorLabel != null)
                                          room.floorLabel!,
                                      ].join(' · '),
                                    ),
                                    onChanged: _busy || !peutGerer
                                        ? null
                                        : (value) => setState(() {
                                            if (value == true) {
                                              _selected.add(room.roomId);
                                            } else {
                                              _selected.remove(room.roomId);
                                            }
                                            _error = null;
                                          }),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    '${selected.length} chambre${selected.length > 1 ? 's' : ''} sélectionnée${selected.length > 1 ? 's' : ''}',
                    style: TextStyle(color: p.textSecondary, fontSize: 14),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(_error!, style: TextStyle(color: p.error)),
                  ),
                ],
                const SizedBox(height: 12),
                PillButton(
                  label: _busy ? 'Lancement du ménage…' : 'Lancer le ménage',
                  icon: PhosphorIconsLight.broom,
                  expand: true,
                  onPressed: _busy || !peutGerer || selected.isEmpty
                      ? null
                      : () => _start(selected),
                ),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Annuler'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
