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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/fiche_laterale.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/order_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../billing/cash_dialog.dart' show CashButton;
import '../billing/charge_labels.dart';
import '../billing/payment_dialog.dart' show iconePaiement;

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
        final outlet = liste.firstWhere(
          (o) => o.id == choisiId,
          orElse: () => liste.first,
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
          action: caisse ? const CashButton() : null,
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
    final chambres = ref.watch(chargeableRoomsProvider);
    final recherche = ref.watch(_rechercheProvider).trim().toLowerCase();
    // Le client de passage paie sur place : il faut une caisse a tenir.
    final passage = ref.watch(sessionProvider).acces.peut('cash.session');

    if (!outlet.allowsRoomCharge) {
      if (passage) {
        return Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
            child: SizedBox(
              width: 250,
              height: 150,
              child: _Passage(outlet: outlet),
            ),
          ),
        );
      }
      return EmptyState(
        icon: PhosphorIconsLight.money,
        title: '${outlet.label} encaisse sur place',
        message: "Ses ventes ne se portent pas sur l'ardoise d'un séjour.",
      );
    }

    return chambres.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: PhosphorIconsLight.warningCircle,
        title: 'Lecture impossible',
        message: '$e',
      ),
      data: (liste) {
        final visibles = recherche.isEmpty
            ? liste
            : liste
                  .where(
                    (c) =>
                        c.roomNumber.toLowerCase().contains(recherche) ||
                        c.guestName.toLowerCase().contains(recherche),
                  )
                  .toList();
        if (liste.isEmpty && !passage) {
          return const EmptyState(
            icon: PhosphorIconsLight.bed,
            title: 'Aucun client en chambre',
            message: 'Une consommation ne se porte que sur un séjour en cours.',
          );
        }
        if (visibles.isEmpty && recherche.isNotEmpty) {
          return EmptyState(
            icon: PhosphorIconsLight.magnifyingGlass,
            title: 'Aucune chambre ne correspond',
            message: '« $recherche » ne correspond à aucun séjour en cours.',
          );
        }
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 250,
            mainAxisExtent: 150,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
          ),
          itemCount: visibles.length + (passage ? 1 : 0),
          itemBuilder: (_, i) => FadeUp(
            index: i.clamp(0, 8),
            child: passage && i == 0
                ? _Passage(outlet: outlet)
                : _Chambre(
                    outlet: outlet,
                    chambre: visibles[passage ? i - 1 : i],
                  ),
          ),
        );
      },
    );
  }
}

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
    final lignes = await afficherFicheLaterale<List<(String, int, int, String?)>>(
      context,
      libelleFermer: 'Fermer sans porter',
      fiche: (panneau) =>
          _Saisie(outlet: outlet, chambre: chambre, panneau: panneau),
    );
    if (lignes == null || lignes.isEmpty || !context.mounted) return;

    // Une ligne apres l'autre : si le plafond du client arrete l'une d'elles,
    // celles d'avant sont bien portees, et le message dit ou l'on en est.
    var portees = 0;
    var total = 0;
    for (final (libelle, prix, quantite, article) in lignes) {
      try {
        await ref
            .read(orderRepositoryProvider)
            .charge(
              outlet: outlet,
              folioId: chambre.folioId,
              label: libelle,
              unitPrice: prix,
              quantity: quantite,
              by: ref.read(sessionProvider).agent?.id,
              menuItemId: article,
            );
      } on StateError catch (e) {
        if (!context.mounted) return;
        final deja = portees == 0
            ? ''
            : '$portees ligne(s) portée(s) (${formatAmount(total)}). ';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$deja« $libelle » refusé : ${e.message}')),
        );
        return;
      }
      portees++;
      total += prix * quantite;
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${formatAmount(total)} porté à la chambre ${chambre.roomNumber}.',
        ),
      ),
    );
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
            'Client de passage',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Sans chambre, paie sur place',
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
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null) return;
    final lignes = await afficherFicheLaterale<List<(String, int, int, String?)>>(
      context,
      libelleFermer: 'Fermer sans encaisser',
      fiche: (panneau) =>
          _Saisie(outlet: outlet, chambre: null, panneau: panneau),
    );
    if (lignes == null || lignes.isEmpty || !context.mounted) return;

    final total = lignes.fold(0, (t, l) => t + l.$2 * l.$3);
    final moyen = await showDialog<PaymentMethod>(
      context: context,
      builder: (_) => _MoyenPassage(total: total),
    );
    if (moyen == null || !context.mounted) return;

    try {
      await ref
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${formatAmount(total)} encaissés (${paymentMethodLabel(moyen)}).',
        ),
      ),
    );
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
  });

  final OutletRow outlet;

  /// `null` : client de passage, qui paie sur place.
  final ChargeableRoom? chambre;

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

  void _valider() => Navigator.of(context).pop([
    for (final l in _lignes)
      (
        l.libelle.text.trim(),
        int.parse(l.prix.text.trim()),
        l.quantite,
        // L'article de la carte, s'il n'a pas ete retouche a la main : c'est
        // lui qui fait sortir le stock.
        l.articleId,
      ),
  ]);

  @override
  Widget build(BuildContext context) {
    final chambre = widget.chambre;

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
              titre: chambre == null
                  ? 'Client de passage'
                  : 'Chambre ${chambre.roomNumber}',
              sousTitre: chambre == null
                  ? 'Il paie sur place, avant de partir'
                  : chambre.departDepasse
                  ? '${chambre.guestName} · départ dépassé'
                  : chambre.guestName,
              badge: _BadgePoint(outlet: widget.outlet),
              valeur: chambre == null ? null : formatAmount(chambre.balance),
              legendeValeur: chambre == null ? null : 'à l’ardoise',
              libelleFermer: chambre == null
                  ? 'Fermer sans encaisser'
                  : 'Fermer sans porter',
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
              ardoise: chambre?.balance,
              onValider: _pret ? _valider : null,
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
class _Barre extends StatelessWidget {
  const _Barre({
    required this.total,
    required this.lignes,
    required this.ardoise,
    required this.onValider,
  });

  final int total;
  final int lignes;

  /// `null` : client de passage, sans ardoise.
  final int? ardoise;
  final VoidCallback? onValider;

  @override
  Widget build(BuildContext context) {
    final passage = ardoise == null;
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
                '${passage ? 'À encaisser' : 'À porter'}'
                '${lignes > 1 ? ', $lignes lignes' : ''}',
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
          if (!passage) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Text(
                  'Ardoise après',
                  style: TextStyle(
                    fontSize: 14,
                    color: AtriumColors.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  formatAmount(ardoise! + total),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AtriumDashColors.title,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ],
            ),
          ],
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
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Annuler'),
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
                  icon: Icon(
                    passage
                        ? PhosphorIconsLight.coins
                        : PhosphorIconsLight.receipt,
                  ),
                  label: Text(
                    passage ? 'Choisir le paiement' : 'Porter à la chambre',
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
