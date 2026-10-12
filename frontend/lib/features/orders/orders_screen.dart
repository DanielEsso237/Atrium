/// Prendre une consommation dans un point de vente (F3.1).
///
/// Un onglet par point de vente, **engendres depuis la base** : ajouter la
/// boite de nuit doit etre un geste d'administration, pas une livraison de
/// l'application.
///
/// L'ecran est fait pour un comptoir de bar : le client annonce son numero de
/// chambre, l'agent le trouve, saisit ce qui a ete consomme, valide. Trois
/// gestes, et le solde du client visible en permanence — c'est lui qui evite
/// de porter 50 000 F sur une ardoise qui en doit deja 200 000 sans que
/// personne ne s'en apercoive.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/fiche_laterale.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/guest_repository.dart' show codeFromId;
import '../../data/repositories/order_repository.dart';
import '../../data/repositories/outlet_tab_repository.dart';
import '../../data/repositories/outlet_repository.dart'
    show receptionOutletCode;
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../billing/cash_dialog.dart' show CashButton;
import '../billing/charge_labels.dart';
import '../billing/invoice_pdf.dart' show partagerPdf, ticketDeComptoir;
import '../billing/payment_dialog.dart' show iconePaiement;
import '../hotel/logo_images.dart' show logoTicketProvider;

/// Le point de vente choisi, et la chambre cherchee.
class _PointChoisi extends Notifier<String?> {
  @override
  String? build() => null;

  void choisir(String id) => state = id;
}

final _pointChoisiProvider = NotifierProvider<_PointChoisi, String?>(
  _PointChoisi.new,
);

class _RechercheChambre extends Notifier<String> {
  @override
  String build() => '';

  void maj(String v) => state = v;
}

final _rechercheProvider = NotifierProvider<_RechercheChambre, String>(
  _RechercheChambre.new,
);

class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key, this.kind = OutletKind.OUTLET});

  /// Les points de vente (restaurant, bar, boutique) ou les services (spa,
  /// piscine, salles) : meme ecran, meme saisie, deux onglets du menu.
  final OutletKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final points = ref.watch(
      outletsProvider(ref.watch(sessionProvider).agent?.id),
    );
    final titre = kind == OutletKind.SERVICE ? 'Services' : 'Points de vente';

    return points.when(
      loading: () => ModuleScaffold(
        title: titre,
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ModuleScaffold(
        title: titre,
        body: EmptyState(
          icon: PhosphorIconsLight.warningCircle,
          title: 'Lecture impossible',
          message: '$e',
        ),
      ),
      data: (tous) {
        final liste = [for (final o in tous) if (o.kind == kind) o];
        if (liste.isEmpty) return _AucunPointDeVente(titre: titre);
        final choisiId = ref.watch(_pointChoisiProvider);
        // Sans choix encore, la reception ouvre sur son propre comptoir
        // plutot que sur le premier onglet venu.
        final aLaReception = ref
            .watch(sessionProvider)
            .acces
            .peut('cash.central');
        final outlet = liste.firstWhere(
          (o) => o.id == choisiId,
          orElse: () => liste.firstWhere(
            (o) => aLaReception && o.code == receptionOutletCode,
            orElse: () => liste.first,
          ),
        );
        final etroit = MediaQuery.sizeOf(context).width < 600;
        final marge = etroit ? 18.0 : 32.0;
        final horaires = outlet.opensAt != null && outlet.closesAt != null
            ? ', ouvert de ${outlet.opensAt!.substring(0, 5)} '
                  'à ${outlet.closesAt!.substring(0, 5)}'
            : '';

        // Le comptoir encaisse le client de passage : il tient sa caisse.
        final caisse = ref.watch(sessionProvider).acces.peut('cash.session');

        return ModuleScaffold(
          title: titre,
          // La caisse s'ouvre sur ce point de vente : c'est lui qui versera
          // sa recette a la reception le soir.
          action: caisse ? CashButton(outletId: outlet.id) : null,
          subtitle: outlet.allowsRoomCharge
              ? '${outlet.label} porte sur la chambre$horaires'
              : '${outlet.label} encaisse sur place$horaires',
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Un onglet par point de vente, engendre depuis la base.
              Padding(
                padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
                child: etroit || !outlet.allowsRoomCharge
                    ? _Points(liste: liste, actif: outlet.id)
                    : Row(
                        children: [
                          Expanded(
                            child: _Points(liste: liste, actif: outlet.id),
                          ),
                          const SizedBox(width: 16),
                          SizedBox(width: 260, child: _ChampChambre()),
                        ],
                      ),
              ),
              if (etroit && outlet.allowsRoomCharge)
                Padding(
                  padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
                  child: _ChampChambre(),
                ),
              Expanded(
                child: _Onglet(outlet: outlet, marge: marge),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Points extends ConsumerWidget {
  const _Points({required this.liste, required this.actif});

  final List<OutletRow> liste;
  final String actif;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilterPills<String>(
    selected: actif,
    onChanged: (id) => ref.read(_pointChoisiProvider.notifier).choisir(id),
    options: [for (final o in liste) FilterOption(o.id, o.label)],
  );
}

class _ChampChambre extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) => SearchPill(
    hint: 'Numéro de chambre, nom…',
    onChanged: (v) => ref.read(_rechercheProvider.notifier).maj(v),
  );
}

class _AucunPointDeVente extends StatelessWidget {
  const _AucunPointDeVente({required this.titre});

  final String titre;

  @override
  Widget build(BuildContext context) => ModuleScaffold(
    title: titre,
    body: EmptyState(
      icon: PhosphorIconsLight.storefront,
      title: titre == 'Services' ? 'Aucun service' : 'Aucun point de vente',
      message:
          "Ils arrivent du serveur : lancez une synchronisation, ou demandez "
          "à l'administration d'en créer un.",
    ),
  );
}

/// Les chambres a qui porter, en tuiles : le numero en grand, c'est ce que
/// le client annonce au comptoir.
class _Onglet extends ConsumerWidget {
  const _Onglet({required this.outlet, required this.marge});

  final OutletRow outlet;
  final double marge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chambres = outlet.allowsRoomCharge
        ? ref.watch(chargeableRoomsProvider).value ?? const <ChargeableRoom>[]
        : const <ChargeableRoom>[];
    final ardoises =
        ref.watch(ardoisesProvider(outlet.id)).value ?? const <Ardoise>[];
    final filtre = ref.watch(_filtreProvider);
    final recherche = ref.watch(_rechercheProvider).trim().toLowerCase();
    // Ouvrir une ardoise, c'est servir : il faut une caisse a tenir.
    final caisse = ref.watch(sessionProvider).acces.peut('cash.session');

    // Le debut de la journee hoteliere : « payees aujourd'hui » commence a
    // l'heure de bascule, pas a minuit.
    final jour = businessDayFor(DateTime.now());
    final debut = DateTime(
      jour.year,
      jour.month,
      jour.day,
      heureBasculeParDefaut,
    ).toUtc();
    bool trouve(String texte) =>
        recherche.isEmpty || texte.toLowerCase().contains(recherche);

    final enCours = ardoises.where((a) => a.ouverte).toList();
    final payees = ardoises
        .where(
          (a) =>
              a.etat == EtatArdoise.payee &&
              a.fermeeLe != null &&
              !a.fermeeLe!.isBefore(debut),
        )
        .toList();
    final montrees = switch (filtre) {
      _Filtre.enCours => enCours,
      _Filtre.payees => payees,
      _Filtre.toutes => ardoises,
    }.where((a) => trouve(a.titre)).toList();
    // Les chambres a qui ouvrir une ardoise : dans la vue du service en
    // cours seulement.
    final lesChambres = filtre == _Filtre.enCours
        ? chambres
              .where((c) => trouve(c.roomNumber) || trouve(c.guestName))
              .toList()
        : const <ChargeableRoom>[];
    final nouveau = caisse && filtre == _Filtre.enCours;

    final tuiles = <Widget>[
      if (nouveau) _Passage(outlet: outlet),
      for (final a in montrees) _TuileArdoise(outlet: outlet, ardoise: a),
      for (final c in lesChambres) _Chambre(outlet: outlet, chambre: c),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(marge, 0, marge, 12),
          child: FilterPills<_Filtre>(
            selected: filtre,
            onChanged: ref.read(_filtreProvider.notifier).choisir,
            options: [
              FilterOption(
                _Filtre.enCours,
                'En cours, non payées',
                count: enCours.length,
              ),
              FilterOption(
                _Filtre.payees,
                'Payées aujourd’hui',
                count: payees.length,
              ),
              FilterOption(_Filtre.toutes, 'Toutes', count: ardoises.length),
            ],
          ),
        ),
        Expanded(
          child: tuiles.isEmpty
              ? EmptyState(
                  icon: recherche.isEmpty
                      ? PhosphorIconsLight.receipt
                      : PhosphorIconsLight.magnifyingGlass,
                  title: recherche.isEmpty
                      ? 'Aucune ardoise'
                      : 'Rien ne correspond',
                  message: recherche.isEmpty
                      ? 'Les ardoises de ${outlet.label} apparaissent ici.'
                      : '« $recherche » ne correspond à aucune ardoise ni '
                            'aucun séjour.',
                )
              : GridView.builder(
                  padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 250,
                    mainAxisExtent: 150,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: tuiles.length,
                  itemBuilder: (_, i) =>
                      FadeUp(index: i.clamp(0, 8), child: tuiles[i]),
                ),
        ),
      ],
    );
  }
}

/// Ce que montre l'ecran Commandes.
enum _Filtre { enCours, payees, toutes }

class _FiltreNotifier extends Notifier<_Filtre> {
  @override
  _Filtre build() => _Filtre.enCours;

  void choisir(_Filtre f) => state = f;
}

final _filtreProvider = NotifierProvider<_FiltreNotifier, _Filtre>(
  _FiltreNotifier.new,
);

class _Chambre extends ConsumerWidget {
  const _Chambre({required this.outlet, required this.chambre});

  final OutletRow outlet;
  final ChargeableRoom chambre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    return Bezel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      onTap: () => _saisir(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                chambre.roomNumber,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.2,
                  height: 1,
                  color: p.text,
                  fontFeatures: tabularFigures,
                ),
              ),
              const Spacer(),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: p.accent,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  PhosphorIconsLight.plus,
                  size: 18,
                  color: p.onAccent,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            chambre.guestName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            chambre.departDepasse
                ? 'Départ dépassé · ${formatAmount(chambre.balance)}'
                : 'Ardoise ${formatAmount(chambre.balance)}',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              color: chambre.departDepasse ? p.error : p.textSecondary,
              fontWeight: chambre.departDepasse ? FontWeight.w600 : null,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saisir(BuildContext context, WidgetRef ref) async {
    final commande = await afficherFicheLaterale<_Commande>(
      context,
      libelleFermer: 'Fermer sans porter',
      fiche: (panneau) =>
          _Saisie(outlet: outlet, chambre: chambre, panneau: panneau),
    );
    if (commande == null || commande.lignes.isEmpty || !context.mounted) {
      return;
    }
    final lignes = commande.lignes;

    // Le client paie tout de suite au comptoir, au lieu de porter sur sa
    // chambre : l'argent va dans le tiroir du point de vente.
    if (commande.payer) {
      await _encaisserAuComptoir(
        context,
        ref,
        outlet,
        lignes,
        client: '${chambre.guestName}, chambre ${chambre.roomNumber}',
      );
      return;
    }

    // Sinon, sur l'ardoise du bar a son nom (decision du 12 octobre) : il
    // paie a la fin, ou on la porte a sa chambre en un geste.
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null) return;
    final String ardoise;
    try {
      ardoise = await ref
          .read(outletTabRepositoryProvider)
          .ouvrir(pointDeVente: outlet, by: agent, guestId: chambre.guestId);
    } on StateError catch (e) {
      if (context.mounted) _dire(context, e.message);
      return;
    }
    if (!context.mounted) return;
    await _servirSurArdoise(
      context,
      ref,
      outlet,
      ardoise,
      lignes,
      ou: 'l’ardoise de ${chambre.guestName}',
    );
  }
}

/// Un message en bas de l'ecran.
void _dire(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));

/// Sert des lignes sur une ardoise, une apres l'autre : si le plafond du
/// client arrete l'une d'elles, celles d'avant sont servies, et le message
/// dit ou l'on en est.
Future<void> _servirSurArdoise(
  BuildContext context,
  WidgetRef ref,
  OutletRow outlet,
  String ardoise,
  List<(String, int, int, String?)> lignes, {
  required String ou,
}) async {
  final agent = ref.read(sessionProvider).agent?.id;
  if (agent == null) return;
  var servies = 0;
  var total = 0;
  for (final (libelle, prix, quantite, article) in lignes) {
    try {
      await ref
          .read(outletTabRepositoryProvider)
          .servir(
            pointDeVente: outlet,
            ardoiseId: ardoise,
            libelle: libelle,
            prixUnitaire: prix,
            quantite: quantite,
            by: agent,
            categorie: OrderRepository.categoriePour(outlet.code),
            menuItemId: article,
          );
    } on StateError catch (e) {
      if (!context.mounted) return;
      final deja = servies == 0
          ? ''
          : '$servies ligne(s) servie(s) (${formatAmount(total)}). ';
      _dire(context, '$deja« $libelle » refusé : ${e.message}');
      return;
    }
    servies++;
    total += prix * quantite;
  }
  if (context.mounted) {
    _dire(context, '${formatAmount(total)} ajouté à $ou.');
  }
}

/// Le client de passage : il consomme, paie sur place et s'en va, sans
/// chambre ni fiche. Premiere tuile de l'onglet, avant les chambres.
class _Passage extends ConsumerWidget {
  const _Passage({required this.outlet});

  final OutletRow outlet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    return Bezel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      onTap: () => _vendre(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(PhosphorIconsLight.storefront, size: 32, color: p.text),
              const Spacer(),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: p.accent,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  PhosphorIconsLight.plus,
                  size: 18,
                  color: p.onAccent,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            'Nouveau client',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'De passage, sans chambre',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              color: p.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _vendre(BuildContext context, WidgetRef ref) async {
    final commande = await afficherFicheLaterale<_Commande>(
      context,
      libelleFermer: 'Fermer sans encaisser',
      fiche: (panneau) =>
          _Saisie(outlet: outlet, chambre: null, panneau: panneau),
    );
    if (commande == null || commande.lignes.isEmpty || !context.mounted) {
      return;
    }
    if (commande.payer) {
      await _encaisserAuComptoir(context, ref, outlet, commande.lignes);
      return;
    }
    // Il consomme et paiera a la fin : une ardoise « Passage n°N ».
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null) return;
    final String ardoise;
    try {
      ardoise = await ref
          .read(outletTabRepositoryProvider)
          .ouvrir(pointDeVente: outlet, by: agent);
    } on StateError catch (e) {
      if (context.mounted) _dire(context, e.message);
      return;
    }
    if (!context.mounted) return;
    await _servirSurArdoise(
      context,
      ref,
      outlet,
      ardoise,
      commande.lignes,
      ou: 'une nouvelle ardoise',
    );
  }
}

/// L'ardoise d'un client au comptoir : son nom ou son numero de passage, ce
/// qu'il doit, et ou elle en est. Toucher la tuile ouvre sa fiche.
class _TuileArdoise extends ConsumerWidget {
  const _TuileArdoise({required this.outlet, required this.ardoise});

  final OutletRow outlet;
  final Ardoise ardoise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final a = ardoise;
    final (etat, couleur) = switch (a.etat) {
      EtatArdoise.aPayer => ('À payer', p.warning),
      EtatArdoise.payee => ('Payée', p.success),
      EtatArdoise.enChambre => ('Sur la chambre', p.textSecondary),
      EtatArdoise.annulee => ('Annulée', p.error),
    };
    return Bezel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      onTap: () => _ouvrir(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                a.client == null
                    ? PhosphorIconsLight.receipt
                    : PhosphorIconsLight.bed,
                size: 28,
                color: p.text,
              ),
              const Spacer(),
              // L'etat en toutes lettres : la couleur n'est qu'un renfort.
              Tag(etat, color: couleur),
            ],
          ),
          const Spacer(),
          Text(
            a.titre,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${a.lignes} consommation${a.lignes > 1 ? 's' : ''} · '
            '${formatAmount(a.ouverte ? a.reste : a.total)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              color: p.textSecondary,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _ouvrir(BuildContext context, WidgetRef ref) async {
    final geste = await afficherFicheLaterale<_Geste>(
      context,
      fiche: (panneau) =>
          _FicheArdoise(outlet: outlet, ardoise: ardoise, panneau: panneau),
    );
    if (geste == null || !context.mounted) return;
    switch (geste) {
      case _Geste.ajouter:
        await _ajouter(context, ref);
      case _Geste.payer:
        await _payer(context, ref);
      case _Geste.chambre:
        await _porterALaChambre(context, ref);
      case _Geste.annuler:
        await _annuler(context, ref);
    }
  }

  Future<void> _ajouter(BuildContext context, WidgetRef ref) async {
    final commande = await afficherFicheLaterale<_Commande>(
      context,
      libelleFermer: 'Fermer sans servir',
      fiche: (panneau) => _Saisie(
        outlet: outlet,
        chambre: null,
        ardoise: ardoise,
        panneau: panneau,
      ),
    );
    if (commande == null || commande.lignes.isEmpty || !context.mounted) {
      return;
    }
    await _servirSurArdoise(
      context,
      ref,
      outlet,
      ardoise.id,
      commande.lignes,
      ou: ardoise.titre,
    );
  }

  Future<void> _payer(BuildContext context, WidgetRef ref) async {
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null) return;
    final total = ardoise.reste;
    final moyen = await showDialog<PaymentMethod>(
      context: context,
      builder: (_) => _MoyenPassage(total: total),
    );
    if (moyen == null || !context.mounted) return;
    // Les lignes, lues avant le paiement : le ticket les reprend.
    final lignes = await ref.read(lignesArdoiseProvider(ardoise.id).future);
    try {
      await ref
          .read(outletTabRepositoryProvider)
          .payer(
            pointDeVente: outlet,
            ardoiseId: ardoise.id,
            moyen: moyen,
            by: agent,
          );
    } on StateError catch (e) {
      if (context.mounted) _dire(context, e.message);
      return;
    }
    if (!context.mounted) return;
    await _proposerTicket(
      context,
      ref,
      outlet,
      ardoise: ardoise.id,
      total: total,
      moyen: moyen,
      lignes: [
        for (final l in lignes)
          if (!l.annulee) (l.libelle, l.montant ~/ l.quantite, l.quantite),
      ],
      client: ardoise.client == null ? null : ardoise.titre,
    );
  }

  Future<void> _porterALaChambre(BuildContext context, WidgetRef ref) async {
    final depot = ref.read(outletTabRepositoryProvider);
    final client = ardoise.clientId;
    final sejour = client == null ? null : await depot.ardoiseDuSejour(client);
    if (!context.mounted) return;
    if (sejour == null) {
      _dire(
        context,
        'Ce client n’a plus de séjour en cours : son ardoise se paie au '
        'comptoir.',
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogue) => AlertDialog(
        icon: const Icon(PhosphorIconsLight.bed, size: 30),
        title: Text('Porter ${formatAmount(ardoise.reste)} sur la chambre ?'),
        content: Text(
          '${ardoise.titre} paiera à son départ. L’ardoise du bar se ferme.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogue).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogue).pop(true),
            child: const Text('Porter sur la chambre'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await depot.porterALaChambre(
        pointDeVente: outlet,
        ardoiseId: ardoise.id,
        ardoiseChambreId: sejour,
      );
    } on StateError catch (e) {
      if (context.mounted) _dire(context, e.message);
      return;
    }
    if (context.mounted) {
      _dire(
        context,
        '${formatAmount(ardoise.reste)} porté sur la chambre de '
        '${ardoise.titre}.',
      );
    }
  }

  Future<void> _annuler(BuildContext context, WidgetRef ref) async {
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null) return;
    final motif = await showDialog<String>(
      context: context,
      builder: (_) => const _MotifAnnulation(),
    );
    if (motif == null || !context.mounted) return;
    try {
      await ref
          .read(outletTabRepositoryProvider)
          .annuler(ardoiseId: ardoise.id, motif: motif, by: agent);
    } on StateError catch (e) {
      if (context.mounted) _dire(context, e.message);
      return;
    }
    if (context.mounted) _dire(context, '${ardoise.titre} annulée : $motif.');
  }
}

/// Ce que l'on fait d'une ardoise depuis sa fiche.
enum _Geste { ajouter, payer, chambre, annuler }

/// La fiche d'une ardoise : ses consommations, et les gestes permis.
class _FicheArdoise extends ConsumerWidget {
  const _FicheArdoise({
    required this.outlet,
    required this.ardoise,
    required this.panneau,
  });

  final OutletRow outlet;
  final Ardoise ardoise;
  final bool panneau;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final lignes =
        ref.watch(lignesArdoiseProvider(ardoise.id)).value ??
        const <LigneArdoise>[];
    final acces = ref.watch(sessionProvider).acces;
    final ouverte = ardoise.ouverte;
    final peutPayer = ouverte && ardoise.reste > 0;
    // Porter a la chambre : un client loge, un point de vente qui porte.
    final peutPorter =
        ouverte && ardoise.clientId != null && outlet.allowsRoomCharge;
    // Annuler : un responsable, et rien de paye.
    final peutAnnuler = ouverte && acces.peut('tab.cancel');
    final style = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14.5,
      color: p.text,
      fontFeatures: tabularFigures,
    );

    return FicheSurface(
      panneau: panneau,
      child: Column(
        children: [
          FicheEnTete(
            panneau: panneau,
            titre: ardoise.titre,
            sousTitre: switch (ardoise.etat) {
              EtatArdoise.aPayer => 'Il paie à la fin',
              EtatArdoise.payee => 'Payée',
              EtatArdoise.enChambre => 'Portée sur la chambre',
              EtatArdoise.annulee => 'Annulée',
            },
            badge: _BadgePoint(outlet: outlet),
            valeur: formatAmount(ouverte ? ardoise.reste : ardoise.total),
            legendeValeur: ouverte ? 'à payer' : 'au total',
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              children: [
                FicheCarte(
                  titre: 'Consommations',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (lignes.isEmpty)
                        Text(
                          'Rien encore.',
                          style: style.copyWith(color: p.textSecondary),
                        ),
                      for (final l in lignes)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${l.quantite} × ${l.libelle}',
                                  style: style.copyWith(
                                    decoration: l.annulee
                                        ? TextDecoration.lineThrough
                                        : null,
                                    color: l.annulee ? p.textSecondary : p.text,
                                  ),
                                ),
                              ),
                              Text(
                                formatAmount(l.montant),
                                style: style.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (ouverte)
            Container(
              padding: EdgeInsets.fromLTRB(
                20,
                14,
                20,
                14 + MediaQuery.paddingOf(context).bottom,
              ),
              decoration: BoxDecoration(
                color: AtriumDashColors.card,
                border: Border(
                  top: BorderSide(color: AtriumDashColors.cardBorder),
                ),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: peutPayer
                        ? () => Navigator.of(context).pop(_Geste.payer)
                        : null,
                    icon: const Icon(PhosphorIconsLight.coins),
                    label: Text('Payer ${formatAmount(ardoise.reste)}'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(_Geste.ajouter),
                    icon: const Icon(PhosphorIconsLight.plus),
                    label: const Text('Ajouter'),
                  ),
                  if (peutPorter)
                    OutlinedButton.icon(
                      onPressed: ardoise.reste > 0
                          ? () => Navigator.of(context).pop(_Geste.chambre)
                          : null,
                      icon: const Icon(PhosphorIconsLight.bed),
                      label: const Text('Porter à la chambre'),
                    ),
                  if (peutAnnuler)
                    TextButton.icon(
                      onPressed: () =>
                          Navigator.of(context).pop(_Geste.annuler),
                      icon: const Icon(PhosphorIconsLight.x),
                      label: const Text('Annuler l’ardoise'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Le motif d'une annulation : client parti sans payer, erreur de saisie.
class _MotifAnnulation extends StatefulWidget {
  const _MotifAnnulation();

  @override
  State<_MotifAnnulation> createState() => _MotifAnnulationState();
}

class _MotifAnnulationState extends State<_MotifAnnulation> {
  final _motif = TextEditingController();

  @override
  void dispose() {
    _motif.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valide = _motif.text.trim().length >= 3;
    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.warningCircle, size: 30),
      title: const Text('Annuler l’ardoise'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Ce qui a été servi reste sorti du stock. Le motif est gardé.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _motif,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Motif',
                hintText: 'Parti sans payer',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Retour'),
        ),
        FilledButton(
          onPressed: valide
              ? () => Navigator.of(context).pop(_motif.text.trim())
              : null,
          child: const Text('Annuler l’ardoise'),
        ),
      ],
    );
  }
}

/// Ce que la fiche de saisie rend : les lignes, et le geste choisi.
class _Commande {
  const _Commande(this.lignes, {this.payer = false});

  /// `(libelle, prix unitaire, quantite, article)`.
  final List<(String, int, int, String?)> lignes;

  /// Le client paie tout de suite, au lieu de porter sur sa chambre.
  final bool payer;
}

/// Encaisse au comptoir : le moyen de paiement, la vente dans le tiroir du
/// point de vente, puis le ticket a remettre au client.
///
/// Pour le client de passage, et pour le client loge qui paie sur place.
Future<void> _encaisserAuComptoir(
  BuildContext context,
  WidgetRef ref,
  OutletRow outlet,
  List<(String, int, int, String?)> lignes, {
  String? client,
}) async {
  final session = ref.read(sessionProvider);
  final agent = session.agent?.id;
  if (agent == null) return;
  final total = lignes.fold(0, (t, l) => t + l.$2 * l.$3);
  final moyen = await showDialog<PaymentMethod>(
    context: context,
    builder: (_) => _MoyenPassage(total: total),
  );
  if (moyen == null || !context.mounted) return;

  final String ardoise;
  try {
    ardoise = await ref
        .read(orderRepositoryProvider)
        .sellWalkIn(outlet: outlet, lines: lignes, method: moyen, by: agent);
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
    return;
  }
  if (!context.mounted) return;
  await _proposerTicket(
    context,
    ref,
    outlet,
    ardoise: ardoise,
    total: total,
    moyen: moyen,
    lignes: [for (final (l, p, q, _) in lignes) (l, p, q)],
    client: client,
  );
}

/// Apres un encaissement au comptoir : le ticket se propose tout de suite,
/// le client attend.
Future<void> _proposerTicket(
  BuildContext context,
  WidgetRef ref,
  OutletRow outlet, {
  required String ardoise,
  required int total,
  required PaymentMethod moyen,
  required List<(String, int, int)> lignes,
  String? client,
}) async {
  final session = ref.read(sessionProvider);
  final ticket = await showDialog<bool>(
    context: context,
    builder: (dialogue) => AlertDialog(
      icon: const Icon(PhosphorIconsLight.checkCircle, size: 30),
      title: Text('${formatAmount(total)} encaissés'),
      content: Text(
        '${paymentMethodLabel(moyen)}, dans la caisse de ${outlet.label}.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogue).pop(false),
          child: const Text('Terminé'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(dialogue).pop(true),
          icon: const Icon(PhosphorIconsLight.receipt),
          label: const Text('Ticket'),
        ),
      ],
    ),
  );
  if (ticket != true || !context.mounted) return;

  try {
    final hotel = await ref.read(hotelProvider.future);
    Uint8List? logo;
    try {
      logo = await ref.read(logoTicketProvider.future);
    } on Object {
      // Sans logo, le ticket reste lisible.
    }
    final numero = codeFromId(ardoise, 'FOL');
    final octets = await ticketDeComptoir(
      hotel: hotel,
      logoNoirBlanc: logo,
      pointDeVente: outlet.label,
      numero: numero,
      date: DateTime.now(),
      lignes: lignes,
      moyen: paymentMethodLabel(moyen),
      client: client,
      agent: session.nomAffiche,
    );
    await partagerPdf(
      octets,
      nom: 'Ticket $numero',
      sujet: 'Ticket ${outlet.label}',
    );
  } on Object catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Le ticket n’a pas pu être fait : $e')),
      );
    }
  }
}

/// Le moyen de paiement du client de passage. Le total, paye en entier :
/// la monnaie rendue se fait au tiroir, elle n'est pas une ligne d'ardoise.
class _MoyenPassage extends StatefulWidget {
  const _MoyenPassage({required this.total});

  final int total;

  @override
  State<_MoyenPassage> createState() => _MoyenPassageState();
}

class _MoyenPassageState extends State<_MoyenPassage> {
  PaymentMethod _moyen = PaymentMethod.CASH;

  static const _moyens = [
    PaymentMethod.CASH,
    PaymentMethod.MOBILE_MONEY,
    PaymentMethod.CARD,
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      icon: const Icon(PhosphorIconsLight.coins, size: 30),
      title: Text('Encaisser ${formatAmount(widget.total)}'),
      content: SizedBox(
        width: 480,
        child: ChoiceTiles<PaymentMethod>(
          selected: _moyen,
          tileWidth: 148,
          onChanged: (m) => setState(() => _moyen = m),
          options: [
            for (final m in _moyens)
              (m, iconePaiement(m), paymentMethodLabel(m)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_moyen),
          child: const Text('Encaisser'),
        ),
      ],
    );
  }
}

/// Une ligne de la saisie : ce qui ira sur l'ardoise.
class _Ligne {
  final libelle = TextEditingController();
  final prix = TextEditingController();
  final focus = FocusNode();
  int quantite = 1;

  /// L'article de la carte choisi, pour le mettre en evidence seulement :
  /// ce qui part est ce que disent les champs.
  String? articleId;

  int get total => (int.tryParse(prix.text.trim()) ?? 0) * quantite;
  bool get complete => libelle.text.trim().isNotEmpty && total > 0;

  void dispose() {
    libelle.dispose();
    prix.dispose();
    focus.dispose();
  }
}

/// Saisie de consommations, dans une fiche comme celle d'une chambre. Rend
/// la liste `(libelle, prix unitaire, quantite, article)`, une par ligne.
///
/// Plusieurs lignes d'un coup : de l'eau et deux plats de poulet se portent
/// ensemble, sans rouvrir la chambre pour chacun. Chaque ligne se choisit
/// dans la carte du point de vente, en tapant quelques lettres ; le prix se
/// remplit, et reste modifiable. Un plat hors carte se tape librement.
///
/// Sous la commande, ce que le client a deja pris ici ; en bas, toujours
/// visible, ce que la commande coute et ou elle emmene l'ardoise.
class _Saisie extends ConsumerStatefulWidget {
  const _Saisie({
    required this.outlet,
    required this.chambre,
    required this.panneau,
    this.ardoise,
  });

  final OutletRow outlet;

  /// `null` : client de passage, ou ardoise deja ouverte.
  final ChargeableRoom? chambre;

  /// L'ardoise ouverte que l'on complete, s'il y en a une.
  final Ardoise? ardoise;

  /// Panneau lateral (tablette couchee) ou feuille (telephone).
  final bool panneau;

  @override
  ConsumerState<_Saisie> createState() => _SaisieState();
}

class _SaisieState extends ConsumerState<_Saisie> {
  final _lignes = [_Ligne()];

  _Ligne get _enCours => _lignes.last;

  void _choisir(_Ligne l, MenuEntry e) {
    setState(() {
      l.articleId = e.id;
      l.libelle.text = e.label;
      l.prix.text = '${e.price}';
    });
  }

  void _ajouter() => setState(() => _lignes.add(_Ligne()));

  void _retirer(_Ligne l) => setState(() {
    _lignes.remove(l);
    l.dispose();
  });

  @override
  void dispose() {
    for (final l in _lignes) {
      l.dispose();
    }
    super.dispose();
  }

  int get _total => _lignes.fold(0, (t, l) => t + l.total);

  /// Pret a porter : aucune ligne a moitie remplie.
  bool get _pret => _lignes.every((l) => l.complete);

  void _valider({bool payer = false}) => Navigator.of(context).pop(
    _Commande([
      for (final l in _lignes)
        (
          l.libelle.text.trim(),
          int.parse(l.prix.text.trim()),
          l.quantite,
          // L'article de la carte, s'il n'a pas ete retouche a la main : c'est
          // lui qui fait sortir le stock.
          l.articleId,
        ),
    ], payer: payer),
  );

  @override
  Widget build(BuildContext context) {
    final chambre = widget.chambre;
    final ardoise = widget.ardoise;
    final mode = ardoise != null
        ? _ModeSaisie.ardoise
        : chambre != null
        ? _ModeSaisie.chambre
        : _ModeSaisie.passage;

    return FicheSurface(
      panneau: widget.panneau,
      child: Padding(
        // Le clavier monte : la barre du total monte avec lui au lieu de
        // passer dessous, et le bouton reste a portee de pouce.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          children: [
            FicheEnTete(
              panneau: widget.panneau,
              titre: ardoise != null
                  ? ardoise.titre
                  : chambre == null
                  ? 'Nouveau client'
                  : 'Chambre ${chambre.roomNumber}',
              sousTitre: ardoise != null
                  ? 'Ajouter à son ardoise'
                  : chambre == null
                  ? 'De passage : il paie à la fin, ou tout de suite'
                  : chambre.departDepasse
                  ? '${chambre.guestName} · départ dépassé'
                  : chambre.guestName,
              badge: _BadgePoint(outlet: widget.outlet),
              valeur: ardoise != null
                  ? formatAmount(ardoise.reste)
                  : chambre == null
                  ? null
                  : formatAmount(chambre.balance),
              legendeValeur: ardoise != null
                  ? 'à payer'
                  : chambre == null
                  ? null
                  : 'à l’ardoise de la chambre',
              libelleFermer: 'Fermer sans servir',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                children: [
                  FicheCarte(titre: 'Commande', child: _formulaire()),
                  // Ce que ce client a deja pris ici : le comptoir le voit
                  // avant de porter.
                  if (chambre != null) ...[
                    const SizedBox(height: 16),
                    _Historique(folioId: chambre.folioId, outlet: widget.outlet),
                  ],
                ],
              ),
            ),
            _Barre(
              total: _total,
              lignes: _lignes.length,
              mode: mode,
              onValider: _pret ? _valider : null,
              onPayer: _pret ? () => _valider(payer: true) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _formulaire() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, l) in _lignes.indexed) ...[
        if (i > 0) Divider(height: 28, color: AtriumDashColors.grid),
        Row(
          children: [
            Expanded(
              child: _ChampArticle(
                ligne: l,
                outletId: widget.outlet.id,
                libelle: _lignes.length > 1
                    ? 'Consommation ${i + 1}'
                    : 'Consommation',
                onChoisi: (e) => _choisir(l, e),
                // Retoucher le libelle a la main : ce n'est plus l'article
                // de la carte.
                onTape: () => setState(() => l.articleId = null),
              ),
            ),
            if (_lignes.length > 1)
              IconButton(
                tooltip: 'Retirer cette ligne',
                icon: const Icon(PhosphorIconsLight.x, size: 20),
                onPressed: () => _retirer(l),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: l.prix,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Prix unitaire',
                  suffixText: 'FCFA',
                ),
              ),
            ),
            const SizedBox(width: 12),
            _Quantite(
              valeur: l.quantite,
              onChange: (v) => setState(() => l.quantite = v),
            ),
          ],
        ),
      ],
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          // Une ligne vide de plus ne sert a rien : on remplit d'abord.
          onPressed: _enCours.complete ? _ajouter : null,
          icon: const Icon(PhosphorIconsLight.plus, size: 18),
          label: const Text('Ajouter une ligne'),
        ),
      ),
    ],
  );
}

/// Le point de vente, en pastille sur la photo : on sait ou l'on porte.
class _BadgePoint extends StatelessWidget {
  const _BadgePoint({required this.outlet});

  final OutletRow outlet;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(10, 7, 14, 7),
    decoration: BoxDecoration(
      color: AtriumColors.white.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          outlet.kind == OutletKind.SERVICE
              ? PhosphorIconsLight.flowerLotus
              : PhosphorIconsLight.storefront,
          size: 18,
          color: AtriumColors.white,
        ),
        const SizedBox(width: 8),
        Text(
          outlet.label,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AtriumColors.white,
          ),
        ),
      ],
    ),
  );
}

/// La barre du bas, toujours visible : le total de la commande, l'ardoise
/// apres coup, et le geste. Le comptoir voit ou il emmene le client avant
/// de valider, pas apres.
/// Pour qui l'on saisit : il decide des gestes de la barre.
enum _ModeSaisie {
  /// Un client loge : sur son ardoise du bar, ou payer tout de suite.
  chambre,

  /// Un nouveau client de passage : ouvrir une ardoise, ou payer tout de
  /// suite.
  passage,

  /// Une ardoise deja ouverte : y ajouter.
  ardoise,
}

class _Barre extends StatelessWidget {
  const _Barre({
    required this.total,
    required this.lignes,
    required this.mode,
    required this.onValider,
    this.onPayer,
  });

  final int total;
  final int lignes;
  final _ModeSaisie mode;

  /// Payer tout de suite, au lieu de mettre sur l'ardoise.
  final VoidCallback? onPayer;
  final VoidCallback? onValider;

  @override
  Widget build(BuildContext context) {
    final ajout = mode == _ModeSaisie.ardoise;
    final forme = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AtriumRadii.md),
    );
    const texteBouton = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );

    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        14 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: AtriumDashColors.card,
        border: Border(top: BorderSide(color: AtriumDashColors.cardBorder)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                'À servir${lignes > 1 ? ', $lignes lignes' : ''}',
                style: TextStyle(
                  fontSize: 15,
                  color: AtriumColors.textSecondary,
                ),
              ),
              const Spacer(),
              // Le chiffre qui change a chaque article choisi : il glisse
              // d'une valeur a l'autre, l'oeil suit le calcul.
              TweenAnimationBuilder<double>(
                tween: Tween(end: total.toDouble()),
                duration: AtriumMotion.of(
                  context,
                  const Duration(milliseconds: 280),
                ),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => Text(
                  formatAmount(v.round()),
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                    color: AtriumDashColors.title,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 54),
                    foregroundColor: AtriumDashColors.title,
                    side: BorderSide(color: AtriumDashColors.cardBorder),
                    shape: forme,
                    textStyle: texteBouton,
                  ),
                  // Payer tout de suite, a la place d'Annuler -- la fiche se
                  // ferme deja par son en-tete. Ajouter a une ardoise ouverte
                  // garde Annuler : elle se paie depuis sa tuile.
                  onPressed: ajout
                      ? () => Navigator.of(context).pop()
                      : onPayer,
                  child: Text(
                    ajout ? 'Annuler' : 'Payer maintenant',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 54),
                    backgroundColor: AtriumColors.mintSoft,
                    foregroundColor: AtriumColors.ink,
                    shape: forme,
                    textStyle: texteBouton,
                  ),
                  onPressed: onValider,
                  icon: const Icon(PhosphorIconsLight.receipt),
                  label: Text(
                    switch (mode) {
                      _ModeSaisie.chambre => 'Sur son ardoise',
                      _ModeSaisie.passage => 'Ouvrir une ardoise',
                      _ModeSaisie.ardoise => 'Ajouter à l’ardoise',
                    },
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Les lettres sans accent ni majuscule : « ndo » trouve « Ndolé ».
String _sansAccent(String texte) {
  const accents = 'àâäáãéèêëíìîïóòôöõúùûüçñ';
  const simples = 'aaaaaeeeeiiiiooooouuuucn';
  final bas = texte.toLowerCase();
  final b = StringBuffer();
  for (final c in bas.split('')) {
    final i = accents.indexOf(c);
    b.write(i < 0 ? c : simples[i]);
  }
  return b.toString();
}

/// Le champ « Consommation » : on tape, la carte du point de vente propose.
///
/// Choisir un article remplit le libelle et le prix (modifiable), et relie
/// la ligne a l'article : c'est ce lien qui fait sortir le stock. Un plat
/// hors carte se tape librement, sans rien choisir.
class _ChampArticle extends ConsumerWidget {
  const _ChampArticle({
    required this.ligne,
    required this.outletId,
    required this.libelle,
    required this.onChoisi,
    required this.onTape,
  });

  final _Ligne ligne;
  final String outletId;
  final String libelle;
  final void Function(MenuEntry) onChoisi;
  final VoidCallback onTape;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final carte =
        ref.watch(menuForOutletProvider(outletId)).asData?.value ??
        const <MenuEntry>[];
    final schema = Theme.of(context).colorScheme;

    return RawAutocomplete<MenuEntry>(
      textEditingController: ligne.libelle,
      focusNode: ligne.focus,
      displayStringForOption: (e) => e.label,
      optionsBuilder: (valeur) {
        final cherche = _sansAccent(valeur.text.trim());
        // Champ vide : toute la carte, pour choisir sans rien taper.
        return [
          for (final e in carte)
            if (e.isAvailable &&
                (cherche.isEmpty ||
                    _sansAccent(e.label).contains(cherche) ||
                    _sansAccent(e.categoryLabel).contains(cherche)))
              e,
        ];
      },
      onSelected: onChoisi,
      fieldViewBuilder: (context, controleur, focus, valider) => TextField(
        controller: controleur,
        focusNode: focus,
        onChanged: (_) => onTape(),
        onSubmitted: (_) => valider(),
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: libelle,
          hintText: carte.isEmpty
              ? 'Ce qui apparaîtra sur la facture'
              : 'Chercher dans la carte, ou saisir librement',
          prefixIcon: const Icon(PhosphorIconsLight.magnifyingGlass, size: 20),
          suffixIcon: ligne.articleId != null
              ? Icon(PhosphorIconsLight.checkCircle, color: schema.primary)
              : null,
        ),
      ),
      optionsViewBuilder: (context, choisir, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280, maxWidth: 460),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              shrinkWrap: true,
              children: [
                for (final e in options)
                  ListTile(
                    dense: true,
                    title: Text(e.label),
                    subtitle: Text(e.categoryLabel),
                    trailing: Text(
                      formatAmount(e.price),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    onTap: () => choisir(e),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Les consommations passees du client dans ce point de vente.
final _historiqueProvider =
    StreamProvider.family<
      List<PastConsumption>,
      ({String folioId, String outletId})
    >(
      (ref, cle) => ref
          .watch(orderRepositoryProvider)
          .watchGuestHistory(
            folioId: cle.folioId,
            outletId: cle.outletId,
            limit: 30,
          ),
    );

/// Ce que l'ardoise ouverte doit deja a ce point de vente.
final _depenseSejourProvider =
    StreamProvider.family<int, ({String folioId, String outletId})>(
      (ref, cle) => ref
          .watch(orderRepositoryProvider)
          .watchStaySpendAt(folioId: cle.folioId, outletId: cle.outletId),
    );

/// Ce que le client a deja pris ici, comme les consommations de la fiche
/// chambre : ce sejour d'abord, puis ses sejours precedents (meme fiche
/// client), pour voir ce qu'il prend d'habitude.
class _Historique extends ConsumerWidget {
  const _Historique({required this.folioId, required this.outlet});

  final String folioId;
  final OutletRow outlet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cle = (folioId: folioId, outletId: outlet.id);
    final lignes =
        ref.watch(_historiqueProvider(cle)).value ?? const <PastConsumption>[];
    final sejour = ref.watch(_depenseSejourProvider(cle)).value ?? 0;

    return FicheCarte(
      titre: 'Déjà consommé ici',
      suffixe: sejour == 0
          ? null
          : Text(
              'Ce séjour : ${formatAmount(sejour)}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AtriumDashColors.title,
                fontFeatures: tabularFigures,
              ),
            ),
      child: lignes.isEmpty
          ? Text(
              'Première consommation de ce client ${outlet.kind == OutletKind.SERVICE ? 'à ce service' : 'à ce point de vente'}.',
              style: TextStyle(fontSize: 15, color: AtriumColors.textSecondary),
            )
          : Column(
              children: [
                for (final (i, c) in lignes.indexed) ...[
                  if (i > 0) Divider(height: 18, color: AtriumDashColors.grid),
                  Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: AtriumDashColors.tileLavender,
                          borderRadius: BorderRadius.circular(38 * 0.3),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          outlet.kind == OutletKind.SERVICE
                              ? PhosphorIconsLight.flowerLotus
                              : PhosphorIconsLight.forkKnife,
                          size: 19,
                          color: AtriumDashColors.tileLavenderInk,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${c.quantity} × ${c.label}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: AtriumDashColors.title,
                              ),
                            ),
                            Text(
                              c.currentStay
                                  ? _jour(c.businessDate)
                                  : '${_jour(c.businessDate)}, séjour précédent',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: AtriumColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatAmount(c.amount),
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: c.currentStay
                              ? AtriumDashColors.title
                              : AtriumColors.textSecondary,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }

  /// « 28/09 » a partir d'une date ISO de la base.
  static String _jour(String iso) =>
      '${iso.substring(8, 10)}/${iso.substring(5, 7)}';
}

class _Quantite extends StatelessWidget {
  const _Quantite({required this.valeur, required this.onChange});

  final int valeur;
  final void Function(int) onChange;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: schema.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            iconSize: 26,
            icon: const Icon(PhosphorIconsLight.minusCircle),
            onPressed: valeur > 1 ? () => onChange(valeur - 1) : null,
          ),
          SizedBox(
            width: 30,
            child: Text(
              '$valeur',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            iconSize: 26,
            icon: const Icon(PhosphorIconsLight.plusCircle),
            onPressed: () => onChange(valeur + 1),
          ),
        ],
      ),
    );
  }
}
