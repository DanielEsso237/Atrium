/// L'historique : tous les mouvements dans l'ordre, et le parcours de chaque
/// client deja venu (demande du 16 octobre).
///
/// Deux vues, une seule question chacune :
///
/// - **Mouvements** -- « que s'est-il passe ? ». Arrivees, departs,
///   reservations prises ou annulees, encaissements, ranges par journee, le
///   plus recent en haut. Ce qui peut encore se defaire porte sa fleche
///   d'annulation, qui demande le code d'un responsable.
/// - **Clients** -- « qui est deja venu, et qu'a-t-il fait ? ». Chaque client
///   qui a dormi a l'hotel, ses sejours, ses nuits, ce qu'il a consomme et
///   paye ; un clic ouvre son parcours ligne par ligne.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/mouvements_queries.dart';
import '../annulations/accord_responsable.dart';
import '../auth/session.dart';
import '../billing/charge_labels.dart';
import 'annuler_mouvement.dart';
import 'mouvements_widgets.dart';

enum _Vue { mouvements, clients }

enum _Periode {
  jour("Aujourd'hui", 0),
  semaine('7 jours', 6),
  mois('30 jours', 29),
  tout('Tout', null);

  const _Periode(this.libelle, this.jours);
  final String libelle;

  /// Jours avant la journee en cours ; `null` : depuis toujours.
  final int? jours;

  DateTime? get depuis {
    final n = jours;
    if (n == null) return null;
    final j = businessDayFor(DateTime.now()).subtract(Duration(days: n));
    return DateTime(j.year, j.month, j.day, heureBasculeParDefaut);
  }
}

enum _Genre {
  tous('Tous', null),
  arrivees('Arrivées', {GenreMouvement.arrivee}),
  departs('Départs', {GenreMouvement.depart}),
  reservations('Réservations', {
    GenreMouvement.reservation,
    GenreMouvement.annulation,
  }),
  argent('Encaissements', {
    GenreMouvement.encaissement,
    GenreMouvement.remboursement,
  });

  const _Genre(this.libelle, this.genres);
  final String libelle;
  final Set<GenreMouvement>? genres;
}

final _mouvementsProvider = StreamProvider.family<List<Mouvement>, _Periode>(
  (ref, periode) => ref
      .watch(databaseProvider)
      .watchMouvements(depuis: periode.depuis, limite: 2000),
);

final _clientsProvider = StreamProvider<List<ClientVenu>>(
  (ref) => ref.watch(databaseProvider).watchClientsVenus(),
);

final _parcoursProvider = StreamProvider.family<List<EtapeParcours>, String>(
  (ref, guestId) => ref.watch(databaseProvider).watchParcoursClient(guestId),
);

class HistoriqueScreen extends ConsumerStatefulWidget {
  const HistoriqueScreen({super.key, this.clientId});

  /// Le client a ouvrir d'emblee (`?client=`), depuis un mouvement.
  final String? clientId;

  @override
  ConsumerState<HistoriqueScreen> createState() => _HistoriqueScreenState();
}

class _HistoriqueScreenState extends ConsumerState<HistoriqueScreen> {
  late _Vue _vue = widget.clientId == null ? _Vue.mouvements : _Vue.clients;
  _Periode _periode = _Periode.semaine;
  _Genre _genre = _Genre.tous;
  String _recherche = '';
  late String? _client = widget.clientId;

  @override
  void didUpdateWidget(covariant HistoriqueScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.clientId != null && widget.clientId != oldWidget.clientId) {
      setState(() {
        _vue = _Vue.clients;
        _client = widget.clientId;
      });
    }
  }

  bool _correspond(List<String?> champs) {
    final q = _recherche.trim().toLowerCase();
    if (q.isEmpty) return true;
    return champs.whereType<String>().join(' ').toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final clients = ref.watch(_clientsProvider).value ?? const <ClientVenu>[];
    final mouvements = ref.watch(_mouvementsProvider(_periode));

    return ModuleScaffold(
      title: 'Historique',
      subtitle:
          '${clients.length} client${clients.length > 1 ? 's' : ''} déjà '
          "venu${clients.length > 1 ? 's' : ''} · tous les mouvements de "
          "l'hôtel, dans l'ordre",
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
            child: Wrap(
              spacing: 16,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterPills<_Vue>(
                  selected: _vue,
                  onChanged: (v) => setState(() => _vue = v),
                  options: [
                    FilterOption(
                      _Vue.mouvements,
                      'Mouvements',
                      count: mouvements.value?.length,
                    ),
                    FilterOption(
                      _Vue.clients,
                      'Clients',
                      count: clients.length,
                    ),
                  ],
                ),
                SizedBox(
                  width: etroit ? double.infinity : 300,
                  child: SearchPill(
                    hint: _vue == _Vue.clients
                        ? 'Nom, code, téléphone…'
                        : 'Client, chambre, référence…',
                    onChanged: (v) => setState(() => _recherche = v),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: switch (_vue) {
              _Vue.mouvements => _vueMouvements(marge, mouvements),
              _Vue.clients => _vueClients(marge, clients),
            },
          ),
        ],
      ),
    );
  }

  // --- Mouvements ---------------------------------------------------------

  Widget _vueMouvements(double marge, AsyncValue<List<Mouvement>> donnees) {
    final acces = ref.watch(sessionProvider).acces;
    final tous = donnees.value ?? const <Mouvement>[];
    final filtres = [
      for (final m in tous)
        if ((_genre.genres == null || _genre.genres!.contains(m.genre)) &&
            _correspond([m.client, m.chambre, m.reference, m.agent, m.detail]))
          m,
    ];

    // Rangement par journee hoteliere : une arrivee a une heure du matin
    // appartient a la veille, comme sur tous les chiffres de l'application.
    final jours = <DateTime, List<Mouvement>>{};
    for (final m in filtres) {
      jours.putIfAbsent(businessDayFor(m.moment), () => []).add(m);
    }

    int compte(_Genre g) => g.genres == null
        ? tous.length
        : tous.where((m) => g.genres!.contains(m.genre)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
          child: Wrap(
            spacing: 16,
            runSpacing: 10,
            children: [
              FilterPills<_Periode>(
                selected: _periode,
                onChanged: (p) => setState(() => _periode = p),
                options: [
                  for (final p in _Periode.values) FilterOption(p, p.libelle),
                ],
              ),
              FilterPills<_Genre>(
                selected: _genre,
                onChanged: (g) => setState(() => _genre = g),
                options: [
                  for (final g in _Genre.values)
                    FilterOption(g, g.libelle, count: compte(g)),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: donnees.isLoading && tous.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : filtres.isEmpty
              ? const EmptyState(
                  icon: PhosphorIconsLight.clockCounterClockwise,
                  title: 'Aucun mouvement',
                  message:
                      'Rien sur cette période. Élargissez la période ou '
                      'retirez un filtre.',
                )
              : ListView(
                  padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
                  children: [
                    for (final e in jours.entries) ...[
                      _EnteteJour(jour: e.key, mouvements: e.value),
                      const SizedBox(height: 8),
                      Bezel(
                        padding: const EdgeInsets.all(6),
                        child: Column(
                          children: [
                            for (final m in e.value)
                              LigneMouvement(
                                mouvement: m,
                                onClient: m.guestId == null
                                    ? null
                                    : () => setState(() {
                                        _vue = _Vue.clients;
                                        _client = m.guestId;
                                      }),
                                onAnnuler: peutProposerAnnulation(acces, m)
                                    ? () => annulerMouvement(context, ref, m)
                                    : null,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  // --- Clients ------------------------------------------------------------

  Widget _vueClients(double marge, List<ClientVenu> clients) {
    final visibles = [
      for (final c in clients)
        if (_correspond([c.nom, c.code, c.telephone, c.nationalite])) c,
    ];
    final choisi = clients.where((c) => c.guestId == _client).firstOrNull;
    final large = MediaQuery.sizeOf(context).width >= 1100;

    final liste = visibles.isEmpty
        ? const EmptyState(
            icon: PhosphorIconsLight.users,
            title: 'Aucun client',
            message:
                'Un client apparaît ici dès sa première arrivée enregistrée.',
          )
        : ListView.separated(
            padding: EdgeInsets.fromLTRB(marge, 0, large ? 12 : marge, 32),
            itemCount: visibles.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _CarteClient(
              client: visibles[i],
              choisi: visibles[i].guestId == _client,
              onTap: () {
                final id = visibles[i].guestId;
                if (large) {
                  setState(() => _client = id);
                } else {
                  _ouvrirParcours(visibles[i]);
                }
              },
            ),
          );

    if (!large) {
      // Arrive par `?client=` sur un ecran etroit : le parcours s'ouvre
      // par-dessus la liste, une seule fois.
      if (choisi != null && widget.clientId == _client) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _client == null) return;
          setState(() => _client = null);
          _ouvrirParcours(choisi);
        });
      }
      return liste;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 4, child: liste),
        Expanded(
          flex: 6,
          child: Padding(
            padding: EdgeInsets.fromLTRB(0, 0, marge, 32),
            child: choisi == null
                ? const Bezel(
                    child: EmptyState(
                      icon: PhosphorIconsLight.user,
                      title: 'Choisissez un client',
                      message:
                          'Son parcours complet s’affiche ici : séjours, '
                          'consommations et paiements.',
                    ),
                  )
                : _Parcours(client: choisi),
          ),
        ),
      ],
    );
  }

  void _ouvrirParcours(ClientVenu client) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AtriumPalette.current.background,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.92,
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
        child: _Parcours(client: client),
      ),
    );
  }
}

class _EnteteJour extends StatelessWidget {
  const _EnteteJour({required this.jour, required this.mouvements});

  final DateTime jour;
  final List<Mouvement> mouvements;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final aujourdhui = businessDayFor(DateTime.now());
    final titre = jour == aujourdhui
        ? "Aujourd'hui"
        : jour == aujourdhui.subtract(const Duration(days: 1))
        ? 'Hier'
        : '${formatWeekdayShort(jour)} ${formatLongDate(jour)}';
    int n(GenreMouvement g) => mouvements.where((m) => m.genre == g).length;
    final encaisse = mouvements.fold<int>(
      0,
      (s, m) => switch (m.genre) {
        GenreMouvement.encaissement => s + (m.montant ?? 0),
        GenreMouvement.remboursement => s - (m.montant ?? 0),
        _ => s,
      },
    );
    final resume = [
      if (n(GenreMouvement.arrivee) > 0)
        '${n(GenreMouvement.arrivee)} arrivée${n(GenreMouvement.arrivee) > 1 ? 's' : ''}',
      if (n(GenreMouvement.depart) > 0)
        '${n(GenreMouvement.depart)} départ${n(GenreMouvement.depart) > 1 ? 's' : ''}',
      if (encaisse != 0) '${formatAmount(encaisse)} encaissés',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            titre,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              resume,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13.5,
                color: p.textSecondary,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CarteClient extends StatelessWidget {
  const _CarteClient({
    required this.client,
    required this.choisi,
    required this.onTap,
  });

  final ClientVenu client;
  final bool choisi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final c = client;
    Widget chiffre(String valeur, String libelle) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          valeur,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: p.text,
            fontFeatures: tabularFigures,
          ),
        ),
        Text(
          libelle,
          style: TextStyle(fontSize: 12, color: p.textSecondary),
        ),
      ],
    );

    return Bezel(
      onTap: onTap,
      core: choisi ? p.accentTint : null,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Monogram(c.nom, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.nom,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    Text(
                      [
                        c.code,
                        if (c.telephone != null) c.telephone!,
                        if (c.nationalite != null) c.nationalite!,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              if (c.vip) ...[
                const SizedBox(width: 6),
                Tag('VIP', color: p.accent),
              ],
              if (c.enCeMoment) ...[
                const SizedBox(width: 6),
                Tag("À l'hôtel", color: p.success),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 22,
            runSpacing: 8,
            children: [
              chiffre('${c.sejours}', c.sejours > 1 ? 'séjours' : 'séjour'),
              chiffre('${c.nuits}', c.nuits > 1 ? 'nuits' : 'nuit'),
              chiffre(formatAmount(c.consomme), 'consommé'),
              if (c.solde != 0)
                chiffre(formatAmount(c.solde), 'reste dû'),
              if (c.derniereVisite != null)
                chiffre(
                  formatShortDate(c.derniereVisite!.toLocal()),
                  'dernière arrivée',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Le parcours d'un client : chaque sejour et chaque ardoise, avec ses
/// lignes et ses paiements.
class _Parcours extends ConsumerWidget {
  const _Parcours({required this.client});

  final ClientVenu client;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final acces = ref.watch(sessionProvider).acces;
    final etapes = ref.watch(_parcoursProvider(client.guestId));

    return ListView(
      children: [
        Bezel(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Monogram(client.nom, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      client.nom,
                      style: atriumDisplay(24, color: p.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${client.sejours} séjour${client.sejours > 1 ? 's' : ''}'
                      ' · ${client.nuits} nuit${client.nuits > 1 ? 's' : ''}'
                      ' · ${formatAmount(client.consomme)} consommés'
                      ' · ${formatAmount(client.paye)} payés',
                      style: TextStyle(
                        fontSize: 14,
                        color: p.textSecondary,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ],
                ),
              ),
              if (acces.peut('guests.read'))
                PillButton(
                  label: 'Fiche',
                  icon: PhosphorIconsLight.identificationCard,
                  tone: PillTone.quiet,
                  compact: true,
                  onPressed: () => context.push('/clients/${client.guestId}'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ...etapes.when(
          loading: () => [
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
          error: (e, _) => [Text('$e')],
          data: (liste) => [
            for (final e in liste) ...[
              _CarteEtape(etape: e),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ],
    );
  }
}

class _CarteEtape extends ConsumerWidget {
  const _CarteEtape({required this.etape});

  final EtapeParcours etape;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final e = etape;
    final acces = ref.watch(sessionProvider).acces;
    final dates = [
      if (e.arrivee != null && e.depart != null)
        'du ${formatShortDate(parseIsoDate(e.arrivee)!)} '
            'au ${formatShortDate(parseIsoDate(e.depart)!)}'
      else if (e.arriveLe != null)
        'le ${formatShortDate(e.arriveLe!.toLocal())}',
      if (e.chambre != null) 'chambre ${e.chambre}',
      if (e.categorie != null) e.categorie!,
    ].join(' · ');

    final (statut, couleur) = switch (e.statut) {
      ReservationStatus.CHECKED_IN => ('En séjour', p.success),
      ReservationStatus.CHECKED_OUT => ('Parti', p.textSecondary),
      ReservationStatus.CANCELLED => ('Annulé', p.error),
      ReservationStatus.NO_SHOW => ('Non venu', p.error),
      null => (e.solde == 0 ? 'Réglée' : 'Ouverte', p.accent),
      _ => ('Réservé', p.accent),
    };

    TextStyle petit([Color? c]) => TextStyle(
      fontSize: 13.5,
      color: c ?? p.text,
      fontFeatures: tabularFigures,
    );

    return Bezel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  e.titre,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              ),
              Tag(statut, color: couleur),
            ],
          ),
          if (dates.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(dates, style: petit(p.textSecondary)),
          ],
          if (e.lignes.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final l in e.lignes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      chargeCategoryIcon(l.categorie),
                      size: 16,
                      color: p.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 46,
                      child: Text(
                        l.journee.length == 10
                            ? '${l.journee.substring(8)}/${l.journee.substring(5, 7)}'
                            : l.journee,
                        style: petit(p.textSecondary),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        [
                          if (l.quantite > 1) '${l.quantite} ×',
                          l.libelle,
                          if (l.pointDeVente != null) '· ${l.pointDeVente}',
                        ].join(' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: petit(
                          l.annulee ? p.textSecondary : null,
                        ).copyWith(
                          decoration: l.annulee
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                    Text(
                      formatAmount(l.montant),
                      style: petit(l.annulee ? p.textSecondary : null)
                          .copyWith(
                            decoration: l.annulee
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                    ),
                  ],
                ),
              ),
          ],
          if (e.paiements.isNotEmpty) ...[
            const Divider(height: 22),
            for (final pm in e.paiements)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      pm.remboursement
                          ? PhosphorIconsLight.arrowCounterClockwise
                          : PhosphorIconsLight.coins,
                      size: 16,
                      color: pm.remboursement ? p.error : p.success,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          pm.remboursement
                              ? 'Encaissement annulé'
                              : paymentMethodLabel(pm.moyen),
                          if (pm.moment != null)
                            formatShortDate(pm.moment!.toLocal()),
                          if (pm.annule) 'annulé',
                        ].join(' · '),
                        style: petit(p.textSecondary),
                      ),
                    ),
                    Text(
                      '${pm.remboursement ? '−' : ''}${formatAmount(pm.montant)}',
                      style: petit(
                        pm.remboursement ? p.error : null,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (!pm.remboursement &&
                        !pm.annule &&
                        acces.peut('cash.session'))
                      IconButton(
                        tooltip: "Annuler l'encaissement",
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          PhosphorIconsLight.arrowCounterClockwise,
                          size: 18,
                        ),
                        onPressed: () => annulerEncaissement(
                          context,
                          ref,
                          paymentId: pm.id,
                          amount: pm.montant,
                          quoi: e.titre,
                        ),
                      ),
                  ],
                ),
              ),
          ],
          const Divider(height: 22),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Consommé ${formatAmount(e.consomme)} · '
                  'payé ${formatAmount(e.paye)}',
                  style: petit(p.textSecondary),
                ),
              ),
              Text(
                e.solde == 0
                    ? 'Soldé'
                    : 'Reste ${formatAmount(e.solde)}',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: e.solde > 0 ? p.error : p.success,
                  fontFeatures: tabularFigures,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
