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
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final points = ref.watch(
      outletsProvider(ref.watch(sessionProvider).agent?.id),
    );

    return points.when(
      loading: () => const ModuleScaffold(
        title: 'Commandes',
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ModuleScaffold(
        title: 'Commandes',
        body: EmptyState(
          icon: PhosphorIconsLight.warningCircle,
          title: 'Lecture impossible',
          message: '$e',
        ),
      ),
      data: (liste) {
        if (liste.isEmpty) return const _AucunPointDeVente();
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
          title: 'Commandes',
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
  const _AucunPointDeVente();

  @override
  Widget build(BuildContext context) => const ModuleScaffold(
    title: 'Commandes',
    body: EmptyState(
      icon: PhosphorIconsLight.storefront,
      title: 'Aucun point de vente',
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
            'Ardoise ${formatAmount(chambre.balance)}',
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

  Future<void> _saisir(BuildContext context, WidgetRef ref) async {
    final lignes = await showDialog<List<(String, int, int)>>(
      context: context,
      builder: (_) => _Saisie(outlet: outlet, chambre: chambre),
    );
    if (lignes == null || lignes.isEmpty || !context.mounted) return;

    // Une ligne apres l'autre : si le plafond du client arrete l'une d'elles,
    // celles d'avant sont bien portees, et le message dit ou l'on en est.
    var portees = 0;
    var total = 0;
    for (final (libelle, prix, quantite) in lignes) {
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
    final lignes = await showDialog<List<(String, int, int)>>(
      context: context,
      builder: (_) => _Saisie(outlet: outlet, chambre: null),
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
  int quantite = 1;

  /// L'article de la carte choisi, pour le mettre en evidence seulement :
  /// ce qui part est ce que disent les champs.
  String? articleId;

  int get total => (int.tryParse(prix.text.trim()) ?? 0) * quantite;
  bool get complete => libelle.text.trim().isNotEmpty && total > 0;

  void dispose() {
    libelle.dispose();
    prix.dispose();
  }
}

/// Saisie de consommations. Rend la liste `(libelle, prix unitaire,
/// quantite)`, une par ligne.
///
/// Plusieurs lignes d'un coup : de l'eau et deux plats de poulet se portent
/// ensemble, sans rouvrir la chambre pour chacun. La carte du point de vente
/// remplit la ligne en cours ; la saisie libre reste toujours possible.
class _Saisie extends ConsumerStatefulWidget {
  const _Saisie({required this.outlet, required this.chambre});

  final OutletRow outlet;

  /// `null` : client de passage, qui paie sur place.
  final ChargeableRoom? chambre;

  @override
  ConsumerState<_Saisie> createState() => _SaisieState();
}

class _SaisieState extends ConsumerState<_Saisie> {
  final _lignes = [_Ligne()];

  _Ligne get _enCours => _lignes.last;

  void _choisir(MenuEntry e) {
    setState(() {
      _enCours.articleId = e.id;
      _enCours.libelle.text = e.label;
      _enCours.prix.text = '${e.price}';
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

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final p = AtriumPalette.current;
    final chambre = widget.chambre;

    return AlertDialog(
      // La carte, les lignes et le recapitulatif depassent vite un ecran de
      // tablette quand le clavier s'ouvre : le contenu doit pouvoir defiler.
      scrollable: true,
      icon: const Icon(PhosphorIconsLight.forkKnife, size: 32),
      title: Text(
        chambre == null
            ? '${widget.outlet.label}, client de passage'
            : '${widget.outlet.label}, chambre ${chambre.roomNumber}',
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              chambre?.guestName ?? 'Il paie sur place, avant de partir.',
              style: TextStyle(fontSize: 16, color: schema.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            // La carte d'abord : elle remplit la derniere ligne.
            _Carte(
              outletId: widget.outlet.id,
              choisi: _enCours.articleId,
              onChoisir: _choisir,
            ),

            for (final (i, l) in _lignes.indexed) ...[
              if (i > 0) const Divider(height: 28),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: l.libelle,
                      // Retoucher le libelle a la main : ce n'est plus
                      // l'article de la carte.
                      onChanged: (_) => setState(() => l.articleId = null),
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: _lignes.length > 1
                            ? 'Consommation ${i + 1}'
                            : 'Consommation',
                        hintText: 'Ce qui apparaîtra sur la facture',
                      ),
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
                  const SizedBox(width: 16),
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
            const SizedBox(height: 8),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: p.hero,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        '${chambre == null ? 'À encaisser' : 'À porter'}'
                        '${_lignes.length > 1 ? ' (${_lignes.length} lignes)' : ''}',
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 15,
                          color: p.onHeroSoft,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        formatAmount(_total),
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.8,
                          color: p.heroAccent,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ],
                  ),
                  // L'ardoise apres coup : le comptoir voit ou il emmene le
                  // client avant de valider, pas apres.
                  if (chambre != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          'Ardoise après',
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 14,
                            color: p.onHeroSoft,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          formatAmount(chambre.balance + _total),
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: p.onHero,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: !_pret
              ? null
              : () => Navigator.of(context).pop([
                  for (final l in _lignes)
                    (
                      l.libelle.text.trim(),
                      int.parse(l.prix.text.trim()),
                      l.quantite,
                    ),
                ]),
          child: Text(
            chambre == null ? 'Choisir le paiement' : 'Porter à la chambre',
          ),
        ),
      ],
    );
  }
}

/// La carte du point de vente, au-dessus de la saisie libre.
///
/// Absente tant qu'elle est vide ou en cours de lecture : la saisie libre
/// reste alors seule, comme avant. Un plat du jour ou un service hors carte
/// doit toujours rester possible.
class _Carte extends ConsumerWidget {
  const _Carte({
    required this.outletId,
    required this.choisi,
    required this.onChoisir,
  });

  final String outletId;
  final String? choisi;
  final void Function(MenuEntry) onChoisir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entrees =
        ref.watch(menuForOutletProvider(outletId)).asData?.value ??
        const <MenuEntry>[];
    if (entrees.isEmpty) return const SizedBox.shrink();

    final schema = Theme.of(context).colorScheme;
    final lignes = <Widget>[];
    String? derniere;

    for (final e in entrees) {
      if (e.categoryLabel != derniere) {
        derniere = e.categoryLabel;
        lignes.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
            child: Text(
              e.categoryLabel,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: schema.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      lignes.add(
        ListTile(
          dense: true,
          selected: e.id == choisi,
          enabled: e.isAvailable,
          title: Text(e.label),
          subtitle: e.isAvailable ? null : const Text('Rupture'),
          trailing: Text(formatAmount(e.price)),
          onTap: e.isAvailable ? () => onChoisir(e) : null,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView(shrinkWrap: true, children: lignes),
        ),
        const Divider(height: 24),
        Text(
          'Ou saisie libre',
          style: TextStyle(fontSize: 12.5, color: schema.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
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
