/// L'arrivee directe : un voyageur sans reservation prend une chambre.
///
/// Demande du 14 octobre. Il arrive a l'hotel, demande une chambre, pour une
/// ou deux nuits ou pour quelques heures, au prix convenu au comptoir -- le
/// prix du sejour entier. En un ecran : la chambre libre, le client (connu
/// ou nouveau), la duree en nuits ou en heures, le prix ; puis il monte.
///
/// Ce que le serveur refuserait est refuse avant d'ecrire : chambre occupee
/// ou hors service, categorie complete sur les nuits, plafond du client.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/confirmation.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';
import '../auth/session.dart';
import '../guests/guest_picker.dart';
import 'reservations_screen.dart'
    show ReservationFilter, reservationFilterProvider;

final _chambresLibresProvider = StreamProvider<List<ChambreLibre>>(
  (ref) => ref.watch(reservationRepositoryProvider).watchChambresLibres(),
);

class ArriveeDirecteScreen extends ConsumerStatefulWidget {
  const ArriveeDirecteScreen({super.key});

  @override
  ConsumerState<ArriveeDirecteScreen> createState() =>
      _ArriveeDirecteScreenState();
}

class _ArriveeDirecteScreenState extends ConsumerState<ArriveeDirecteScreen> {
  String? _chambreId;
  String? _clientId;
  UniteSejour _unite = UniteSejour.NIGHTS;
  int _duree = 1;
  final _prix = TextEditingController();

  /// Le prix touche a la main : on ne le recalcule plus quand la duree ou
  /// la chambre change.
  bool _prixSaisi = false;
  bool _busy = false;

  @override
  void dispose() {
    _prix.dispose();
    super.dispose();
  }

  int get _max => _unite == UniteSejour.NIGHTS ? 365 : 24;

  /// Le prix propose : en nuits, le tarif de la categorie fois les nuits. En
  /// heures, il n'y a pas de tarif : rien n'est propose.
  void _proposerPrix(List<ChambreLibre> chambres) {
    if (_prixSaisi) return;
    final chambre = chambres.where((c) => c.id == _chambreId).firstOrNull;
    _prix.text = _unite == UniteSejour.NIGHTS && chambre != null
        ? '${chambre.tarif * _duree}'
        : '';
  }

  Future<void> _enregistrer(List<ChambreLibre> chambres) async {
    final agent = ref.read(sessionProvider).agent?.id;
    final chambre = chambres.where((c) => c.id == _chambreId).firstOrNull;
    final prix = int.tryParse(_prix.text.trim());
    if (agent == null || chambre == null || _clientId == null || prix == null) {
      return;
    }
    setState(() => _busy = true);
    final depot = ref.read(reservationRepositoryProvider);
    try {
      await depot.arriveeDirecte(
        guestId: _clientId!,
        roomId: chambre.id,
        unite: _unite,
        duree: _duree,
        prix: prix,
        by: agent,
      );
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      montrerRefus(context, e.message);
      return;
    }
    if (!mounted) return;
    final client = await ref.read(guestRepositoryProvider).byId(_clientId!);
    if (!mounted) return;
    final nom = client == null
        ? 'Le client'
        : '${client.firstName} ${client.lastName}'.trim();
    final duree = _unite == UniteSejour.HOURS
        ? '$_duree h'
        : '$_duree nuit${_duree > 1 ? 's' : ''}';
    montrerSucces(
      context,
      '$nom est arrivé, chambre ${chambre.numero}, $duree pour '
      '${formatAmount(prix)}.',
    );
    // Sur « Toutes », comme apres une reservation : le sejour qu'on vient
    // d'ouvrir doit etre la, quel que soit le filtre laisse le matin.
    ref.read(reservationFilterProvider.notifier).select(ReservationFilter.all);
    context.go('/reservations');
  }

  @override
  Widget build(BuildContext context) {
    final chambres =
        ref.watch(_chambresLibresProvider).value ?? const <ChambreLibre>[];
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final prix = int.tryParse(_prix.text.trim());
    final pret =
        _chambreId != null &&
        _clientId != null &&
        prix != null &&
        prix >= 0 &&
        !_busy;

    return ModuleScaffold(
      title: 'Nouvelle arrivée',
      subtitle: 'Un voyageur sans réservation prend une chambre',
      action: PillButton(
        label: 'Enregistrer l’arrivée',
        icon: PhosphorIconsLight.signIn,
        tone: PillTone.accent,
        onPressed: pret ? () => _enregistrer(chambres) : null,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
        children: [
          _Etape(
            titre: '1. La chambre',
            child: chambres.isEmpty
                ? Text(
                    'Aucune chambre libre en ce moment.',
                    style: TextStyle(color: AtriumPalette.current.textSecondary),
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in chambres)
                        ChoiceChip(
                          selected: c.id == _chambreId,
                          onSelected: (_) => setState(() {
                            _chambreId = c.id;
                            _proposerPrix(chambres);
                          }),
                          label: Text(
                            '${c.numero} · ${c.categorie}'
                            '${c.propre ? '' : ' · à nettoyer'}',
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 14),
          _Etape(
            titre: '2. Le client',
            child: GuestPicker(
              selectedId: _clientId,
              onSelected: (id) => setState(() => _clientId = id),
            ),
          ),
          const SizedBox(height: 14),
          _Etape(
            titre: '3. La durée et le prix',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilterPills<UniteSejour>(
                  selected: _unite,
                  onChanged: (u) => setState(() {
                    _unite = u;
                    _duree = _duree.clamp(1, _max);
                    _proposerPrix(chambres);
                  }),
                  options: const [
                    FilterOption(UniteSejour.NIGHTS, 'En nuits'),
                    FilterOption(UniteSejour.HOURS, 'En heures'),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    IconButton.outlined(
                      tooltip: 'Moins',
                      onPressed: _duree > 1
                          ? () => setState(() {
                              _duree--;
                              _proposerPrix(chambres);
                            })
                          : null,
                      icon: const Icon(PhosphorIconsLight.minus),
                    ),
                    SizedBox(
                      width: 120,
                      child: Text(
                        _unite == UniteSejour.HOURS
                            ? '$_duree heure${_duree > 1 ? 's' : ''}'
                            : '$_duree nuit${_duree > 1 ? 's' : ''}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ),
                    IconButton.outlined(
                      tooltip: 'Plus',
                      onPressed: _duree < _max
                          ? () => setState(() {
                              _duree++;
                              _proposerPrix(chambres);
                            })
                          : null,
                      icon: const Icon(PhosphorIconsLight.plus),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: 320,
                  child: TextField(
                    controller: _prix,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() => _prixSaisi = true),
                    decoration: InputDecoration(
                      labelText: 'Prix du séjour entier',
                      suffixText: 'FCFA',
                      helperText: _unite == UniteSejour.HOURS
                          ? 'Le prix convenu pour ces heures.'
                          : 'Proposé au tarif de la chambre ; modifiable.',
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

/// Une etape du formulaire, dans sa carte.
class _Etape extends StatelessWidget {
  const _Etape({required this.titre, required this.child});

  final String titre;
  final Widget child;

  @override
  Widget build(BuildContext context) => Bezel(
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [Eyebrow(titre), const SizedBox(height: 12), child],
    ),
  );
}
