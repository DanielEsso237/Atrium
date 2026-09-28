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
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database.dart';
import '../../data/repositories/order_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final points = ref.watch(outletsProvider);

    return points.when(
      loading: () => const ModuleScaffold(
        title: 'Commandes',
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ModuleScaffold(
        title: 'Commandes',
        body: Center(child: Text('Erreur : $e')),
      ),
      data: (liste) {
        if (liste.isEmpty) return const _AucunPointDeVente();

        return DefaultTabController(
          length: liste.length,
          child: ModuleScaffold(
            title: 'Commandes',
            body: Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: TabBar(
                    isScrollable: liste.length > 3,
                    labelStyle: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                    tabs: [
                      for (final o in liste)
                        Tab(height: 56, text: o.label),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [for (final o in liste) _Onglet(outlet: o)],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AucunPointDeVente extends StatelessWidget {
  const _AucunPointDeVente();

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return ModuleScaffold(
      title: 'Commandes',
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.storefront_outlined, size: 72, color: schema.outline),
              const SizedBox(height: 20),
              Text(
                'Aucun point de vente.',
                style: TextStyle(fontSize: 20, color: schema.outline),
              ),
              const SizedBox(height: 8),
              Text(
                'Ils arrivent du serveur : appuyez sur la fleche de '
                'synchronisation, ou demandez a l\'administration d\'en '
                'creer un.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: schema.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le contenu d'un onglet : la liste des chambres a qui porter.
class _Onglet extends ConsumerWidget {
  const _Onglet({required this.outlet});

  final OutletRow outlet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schema = Theme.of(context).colorScheme;
    final chambres = ref.watch(chargeableRoomsProvider);

    if (!outlet.allowsRoomCharge) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.money_off, size: 64, color: schema.outline),
              const SizedBox(height: 16),
              Text(
                '${outlet.label} encaisse sur place.',
                style: const TextStyle(fontSize: 19),
              ),
              const SizedBox(height: 8),
              Text(
                'Ses ventes ne se portent pas sur l\'ardoise d\'un sejour.',
                style: TextStyle(fontSize: 16, color: schema.outline),
              ),
            ],
          ),
        ),
      );
    }

    return chambres.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Erreur : $e')),
      data: (liste) {
        if (liste.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Text(
                'Aucun client en chambre.\n'
                'Une consommation ne peut se porter que sur un sejour en '
                'cours.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, color: schema.outline),
              ),
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: liste.length,
          itemBuilder: (_, i) => _Chambre(outlet: outlet, chambre: liste[i]),
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
    final schema = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _saisir(context, ref),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              // Le numero d'abord et en grand : c'est ce que le client
              // annonce au comptoir.
              SizedBox(
                width: 96,
                child: Text(
                  chambre.roomNumber,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chambre.guestName,
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Ardoise : ${formatAmount(chambre.balance)}',
                      style: TextStyle(fontSize: 15, color: schema.outline),
                    ),
                  ],
                ),
              ),
              Icon(Icons.add_circle_outline, size: 30, color: schema.primary),
            ],
          ),
        ),
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
          '${formatAmount(prix * quantite)} porte a la chambre '
          '${chambre.roomNumber}.',
        ),
      ),
    );
  }
}

/// Saisie d'une consommation. Rend `(libelle, prix unitaire, quantite)`.
class _Saisie extends StatefulWidget {
  const _Saisie({required this.outlet, required this.chambre});

  final OutletRow outlet;
  final ChargeableRoom chambre;

  @override
  State<_Saisie> createState() => _SaisieState();
}

class _SaisieState extends State<_Saisie> {
  final _libelle = TextEditingController();
  final _prix = TextEditingController();
  int _quantite = 1;

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

    return AlertDialog(
      title: Text('${widget.outlet.label} — chambre ${widget.chambre.roomNumber}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.chambre.guestName,
              style: TextStyle(fontSize: 16, color: schema.outline),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _libelle,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Consommation',
                hintText: 'Ce qui apparaitra sur la facture',
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
                      labelText: 'Prix unitaire (FCFA)',
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
                color: schema.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text('A porter', style: TextStyle(fontSize: 17)),
                      const Spacer(),
                      Text(
                        formatAmount(_total),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
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
                        'Ardoise apres',
                        style: TextStyle(fontSize: 15, color: schema.outline),
                      ),
                      const Spacer(),
                      Text(
                        formatAmount(widget.chambre.balance + _total),
                        style: TextStyle(
                          fontSize: 16,
                          color: schema.outline,
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
              : () => Navigator.of(context).pop((
                  _libelle.text,
                  int.parse(_prix.text.trim()),
                  _quantite,
                )),
          child: const Text('Porter a la chambre'),
        ),
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
            icon: const Icon(Icons.remove_circle_outline),
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
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => onChange(valeur + 1),
          ),
        ],
      ),
    );
  }
}
