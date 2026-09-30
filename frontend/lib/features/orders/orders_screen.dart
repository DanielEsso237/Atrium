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
import '../../data/repositories/order_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

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
        title: 'Restaurant',
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ModuleScaffold(
        title: 'Restaurant',
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
            ? '  ·  ouvert de ${outlet.opensAt!.substring(0, 5)} '
                  'à ${outlet.closesAt!.substring(0, 5)}'
            : '';

        return ModuleScaffold(
          title: 'Restaurant',
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
    title: 'Restaurant',
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

    if (!outlet.allowsRoomCharge) {
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
        if (liste.isEmpty) {
          return const EmptyState(
            icon: PhosphorIconsLight.bed,
            title: 'Aucun client en chambre',
            message: 'Une consommation ne se porte que sur un séjour en cours.',
          );
        }
        if (visibles.isEmpty) {
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
          itemCount: visibles.length,
          itemBuilder: (_, i) => FadeUp(
            index: i.clamp(0, 8),
            child: _Chambre(outlet: outlet, chambre: visibles[i]),
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
                  fontWeight: FontWeight.w800,
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
    final saisie = await showDialog<(String, int, int)>(
      context: context,
      builder: (_) => _Saisie(outlet: outlet, chambre: chambre),
    );
    if (saisie == null || !context.mounted) return;

    final (libelle, prix, quantite) = saisie;

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${formatAmount(prix * quantite)} porté à la chambre '
          '${chambre.roomNumber}.',
        ),
      ),
    );
  }
}

/// Saisie d'une consommation. Rend `(libelle, prix unitaire, quantite)`.
///
/// La carte du point de vente est proposee au-dessus de la saisie libre : un
/// article choisi remplit le libelle et le prix, rien de plus. Ce qui part
/// vers l'ardoise est toujours ce que disent les champs.
class _Saisie extends ConsumerStatefulWidget {
  const _Saisie({required this.outlet, required this.chambre});

  final OutletRow outlet;
  final ChargeableRoom chambre;

  @override
  ConsumerState<_Saisie> createState() => _SaisieState();
}

class _SaisieState extends ConsumerState<_Saisie> {
  final _libelle = TextEditingController();
  final _prix = TextEditingController();
  int _quantite = 1;

  /// L'article de la carte choisi, s'il y en a un. Sert seulement a le
  /// mettre en evidence : ce qui part est ce que disent les champs.
  String? _articleId;

  void _choisir(MenuEntry e) {
    setState(() {
      _articleId = e.id;
      _libelle.text = e.label;
      _prix.text = '${e.price}';
    });
  }

  @override
  void dispose() {
    _libelle.dispose();
    _prix.dispose();
    super.dispose();
  }

  int get _total => (int.tryParse(_prix.text.trim()) ?? 0) * _quantite;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final p = AtriumPalette.current;

    return AlertDialog(
      // La carte + les champs + le recapitulatif depassent vite un ecran de
      // tablette quand le clavier s'ouvre : le contenu doit pouvoir defiler.
      scrollable: true,
      icon: const Icon(PhosphorIconsLight.forkKnife, size: 32),
      title: Text(
        '${widget.outlet.label} · chambre ${widget.chambre.roomNumber}',
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.chambre.guestName,
              style: TextStyle(fontSize: 16, color: schema.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            // La carte d'abord, la saisie libre juste en dessous.
            _Carte(
              outletId: widget.outlet.id,
              choisi: _articleId,
              onChoisir: _choisir,
            ),

            TextField(
              controller: _libelle,
              // Retoucher le libelle a la main : ce n'est plus l'article de
              // la carte, la mise en evidence disparait.
              onChanged: (_) => setState(() => _articleId = null),
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Consommation',
                hintText: 'Ce qui apparaîtra sur la facture',
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _prix,
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
                  valeur: _quantite,
                  onChange: (v) => setState(() => _quantite = v),
                ),
              ],
            ),
            const SizedBox(height: 18),

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
                        'À porter',
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
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8,
                          color: p.heroAccent,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // L'ardoise apres coup : le comptoir voit ou il emmene le
                  // client avant de valider, pas apres.
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
                        formatAmount(widget.chambre.balance + _total),
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
          onPressed: _total <= 0 || _libelle.text.trim().isEmpty
              ? null
              : () => Navigator.of(
                  context,
                ).pop((_libelle.text, int.parse(_prix.text.trim()), _quantite)),
          child: const Text('Porter à la chambre'),
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