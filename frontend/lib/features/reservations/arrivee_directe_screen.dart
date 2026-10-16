/// La nouvelle arrivee : un voyageur sans reservation prend une chambre.
///
/// Demande du 14 octobre, refaite le 16 : le meme formulaire que la nouvelle
/// reservation -- des etapes numerotees qui se cochent, le recapitulatif a
/// droite --, avec ce qui lui est propre : la duree en nuits ou en heures,
/// le prix du sejour entier convenu au comptoir, et la piece d'identite
/// **obligatoire** (le client est devant soi : on la photographie).
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
import '../../data/repositories/id_photo_repository.dart' show IdPhotoSide;
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart';
import '../auth/session.dart';
import '../guests/guest_picker.dart';
import 'reservations_screen.dart'
    show ReservationFilter, reservationFilterProvider;
import '../guests/id_photos.dart';
import 'etape_formulaire.dart';

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

  String get _dureeTexte => _unite == UniteSejour.HOURS
      ? '$_duree heure${_duree > 1 ? 's' : ''}'
      : '$_duree nuit${_duree > 1 ? 's' : ''}';

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
    montrerSucces(
      context,
      '$nom est arrivé, chambre ${chambre.numero}, $_dureeTexte pour '
      '${formatAmount(prix)}.',
    );
    // Sur « Toutes », comme apres une reservation : le sejour qu'on vient
    // d'ouvrir doit etre la, quel que soit le filtre laisse le matin.
    ref.read(reservationFilterProvider.notifier).select(ReservationFilter.all);
    context.go('/reservations');
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final chambres =
        ref.watch(_chambresLibresProvider).value ?? const <ChambreLibre>[];
    final chambre = chambres.where((c) => c.id == _chambreId).firstOrNull;
    final photos = _clientId == null
        ? null
        : ref.watch(idPhotosProvider(_clientId!)).value;
    final pieceFaite = photos?.length == IdPhotoSide.values.length;
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final prix = int.tryParse(_prix.text.trim());
    final pret =
        _chambreId != null &&
        _clientId != null &&
        pieceFaite &&
        prix != null &&
        prix >= 0 &&
        !_busy;

    var numero = 0;
    final etapes = <EtapeFormulaire>[
      EtapeFormulaire(
        numero: ++numero,
        titre: 'Le client',
        fait: _clientId != null,
        child: GuestPicker(
          selectedId: _clientId,
          onSelected: (id) => setState(() => _clientId = id),
        ),
      ),
      // Obligatoire a l'arrivee : le client est devant soi. La photo va sur
      // sa fiche, comme a la reservation.
      if (_clientId != null)
        EtapeFormulaire(
          numero: ++numero,
          titre: 'La pièce d’identité',
          fait: pieceFaite,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Photographiez le recto et le verso : l’arrivée ne '
                's’enregistre pas sans eux.',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 14,
                  height: 1.45,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: IdPhotoPair(
                    key: ValueKey(_clientId),
                    guestId: _clientId!,
                  ),
                ),
              ),
            ],
          ),
        ),
      EtapeFormulaire(
        numero: ++numero,
        titre: 'La durée',
        fait: _duree > 0,
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
                    _dureeTexte,
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
          ],
        ),
      ),
      EtapeFormulaire(
        numero: ++numero,
        titre: 'La chambre',
        fait: _chambreId != null,
        child: chambres.isEmpty
            ? Text(
                'Aucune chambre libre en ce moment.',
                style: TextStyle(color: p.textSecondary),
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
      EtapeFormulaire(
        numero: ++numero,
        titre: 'Le prix',
        fait: prix != null,
        child: TextField(
          controller: _prix,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() => _prixSaisi = true),
          decoration: InputDecoration(
            labelText: 'Prix du séjour entier (FCFA)',
            prefixIcon: const Icon(PhosphorIconsLight.tag, size: 22),
            helperText: _unite == UniteSejour.HOURS
                ? 'Le prix convenu pour ces heures.'
                : chambre == null
                ? 'Proposé au tarif de la chambre choisie ; modifiable.'
                : 'Tarif de référence : ${formatAmount(chambre.tarif)} / nuit',
          ),
        ),
      ),
    ];

    final ticket = _Ticket(
      clientId: _clientId,
      pieceFaite: pieceFaite,
      duree: _dureeTexte,
      chambre: chambre == null
          ? null
          : '${chambre.numero} · ${chambre.categorie}',
      prix: prix ?? 0,
      peutEnregistrer: pret,
      occupe: _busy,
      onEnregistrer: () => _enregistrer(chambres),
    );

    final formulaire = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < etapes.length; i++)
          FadeUp(
            key: ValueKey(etapes[i].titre),
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: etapes[i],
            ),
          ),
      ],
    );

    return ModuleScaffold(
      title: 'Nouvelle arrivée',
      subtitle: 'Un voyageur sans réservation prend une chambre',
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

/// Le recapitulatif, comme celui de la reservation : ce qui sera
/// enregistre, et le bouton pour le faire.
class _Ticket extends ConsumerWidget {
  const _Ticket({
    required this.clientId,
    required this.pieceFaite,
    required this.duree,
    required this.chambre,
    required this.prix,
    required this.peutEnregistrer,
    required this.occupe,
    required this.onEnregistrer,
  });

  final String? clientId;
  final bool pieceFaite;
  final String duree;
  final String? chambre;
  final int prix;
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

    // Ce qui manque encore, dit en clair sous le bouton.
    final manque = [
      if (clientId == null) 'un client',
      if (clientId != null && !pieceFaite) 'les photos de sa pièce',
      if (chambre == null) 'une chambre',
    ];

    return Bezel(
      core: p.hero,
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Récapitulatif', style: atriumDisplay(26, color: p.onHero)),
          const SizedBox(height: 14),
          FutureBuilder(
            key: ValueKey(clientId),
            future: clientId == null
                ? null
                : ref.read(guestRepositoryProvider).byId(clientId!),
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
            PhosphorIconsLight.identificationCard,
            'Pièce d’identité',
            clientId == null
                ? null
                : (pieceFaite ? 'photographiée' : 'à faire'),
          ),
          ligne(PhosphorIconsLight.clock, 'Durée', duree),
          ligne(PhosphorIconsLight.door, 'Chambre', chambre),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Container(
              height: 1,
              color: p.onHero.withValues(alpha: 0.14),
            ),
          ),
          Text(
            'Prix du séjour, $duree',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 13.5,
              color: doux,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            formatAmount(prix),
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.2,
              color: p.heroAccent,
              fontFeatures: tabularFigures,
            ),
          ),
          const SizedBox(height: 18),
          PillButton(
            label: occupe ? 'Enregistrement…' : 'Enregistrer l’arrivée',
            icon: PhosphorIconsLight.signIn,
            tone: PillTone.accent,
            expand: true,
            onPressed: peutEnregistrer ? onEnregistrer : null,
          ),
          if (!peutEnregistrer && !occupe && manque.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Il manque ${manque.join(', ')}.',
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
