/// Les points de vente : liste, creation, modification, desactivation.
///
/// Jamais de suppression : les commandes passees y renvoient. Desactive, un
/// point de vente sort des onglets de l'ecran Commande et reste ici, pret a
/// etre reactive.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/repositories/repository_providers.dart';

final _tousLesPointsDeVente = StreamProvider<List<OutletRow>>(
  (ref) => ref.watch(outletRepositoryProvider).watchAll(),
);

class OutletsSection extends ConsumerWidget {
  const OutletsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final points = ref.watch(_tousLesPointsDeVente);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(child: Eyebrow('Points de vente')),
            PillButton(
              label: 'Nouveau point de vente',
              icon: PhosphorIconsLight.plus,
              tone: PillTone.accent,
              compact: true,
              onPressed: () => _ouvrir(context),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ...points.when(
          loading: () => [const Center(child: CircularProgressIndicator())],
          error: (e, _) => [Text('Lecture impossible : $e')],
          data: (liste) => liste.isEmpty
              ? [
                  const EmptyState(
                    icon: PhosphorIconsLight.storefront,
                    title: 'Aucun point de vente',
                    message: 'Créez le restaurant, le bar, la piscine…',
                  ),
                ]
              : [
                  for (final o in liste)
                    _LignePointDeVente(
                      point: o,
                      onTap: () => _ouvrir(context, existant: o),
                    ),
                ],
        ),
      ],
    );
  }

  void _ouvrir(BuildContext context, {OutletRow? existant}) {
    showDialog<void>(
      context: context,
      builder: (_) => _OutletDialog(existant: existant),
    );
  }
}

class _LignePointDeVente extends StatelessWidget {
  const _LignePointDeVente({required this.point, required this.onTap});

  final OutletRow point;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final horaires = point.opensAt == null && point.closesAt == null
        ? 'Horaires libres'
        : '${point.opensAt ?? '…'} – ${point.closesAt ?? '…'}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        point.label,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: point.isActive ? p.text : p.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${point.code} · $horaires · ordre ${point.sortOrder}',
                        style: TextStyle(fontSize: 13.5, color: p.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (point.allowsRoomCharge) ...[
                  const Tag('À la chambre'),
                  const SizedBox(width: 8),
                ],
                if (!point.isActive) const Tag('Désactivé'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OutletDialog extends ConsumerStatefulWidget {
  const _OutletDialog({this.existant});

  final OutletRow? existant;

  @override
  ConsumerState<_OutletDialog> createState() => _OutletDialogState();
}

class _OutletDialogState extends ConsumerState<_OutletDialog> {
  late final _code = TextEditingController(text: widget.existant?.code);
  late final _libelle = TextEditingController(text: widget.existant?.label);
  late final _ouverture = TextEditingController(text: widget.existant?.opensAt);
  late final _fermeture = TextEditingController(
    text: widget.existant?.closesAt,
  );
  late final _ordre = TextEditingController(
    text: '${widget.existant?.sortOrder ?? 0}',
  );
  late bool _chambre = widget.existant?.allowsRoomCharge ?? true;
  late bool _actif = widget.existant?.isActive ?? true;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_code, _libelle, _ouverture, _fermeture, _ordre]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _heure(String v) => v.trim().isEmpty ? null : v.trim();

  Future<void> _enregistrer() async {
    setState(() => _busy = true);
    final depot = ref.read(outletRepositoryProvider);
    final ordre = int.tryParse(_ordre.text.trim()) ?? 0;
    final existant = widget.existant;
    try {
      if (existant == null) {
        await depot.create(
          code: _code.text,
          label: _libelle.text,
          opensAt: _heure(_ouverture.text),
          closesAt: _heure(_fermeture.text),
          allowsRoomCharge: _chambre,
          sortOrder: ordre,
        );
      } else {
        await depot.update(
          id: existant.id,
          code: _code.text,
          label: _libelle.text,
          opensAt: _heure(_ouverture.text),
          closesAt: _heure(_fermeture.text),
          allowsRoomCharge: _chambre,
          sortOrder: ordre,
          isActive: _actif,
        );
      }
    } on StateError catch (e) {
      // Le depot refuse ce que le serveur refuserait : on le dit tel quel.
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final creation = widget.existant == null;

    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.storefront, size: 30),
      title: Text(creation ? 'Nouveau point de vente' : 'Point de vente'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: _code,
                      decoration: const InputDecoration(labelText: 'Code'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _libelle,
                      decoration: const InputDecoration(labelText: 'Libellé'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ouverture,
                      decoration: const InputDecoration(
                        labelText: 'Ouverture',
                        hintText: '07:00',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _fermeture,
                      decoration: const InputDecoration(
                        labelText: 'Fermeture',
                        hintText: '23:00',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _ordre,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Ordre'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _chambre,
                onChanged: (v) => setState(() => _chambre = v),
                title: const Text('Facturation à la chambre'),
                subtitle: const Text(
                  'Une consommation peut être portée sur l’ardoise du client.',
                ),
              ),
              if (!creation)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _actif,
                  onChanged: (v) => setState(() => _actif = v),
                  title: const Text('Actif'),
                  subtitle: const Text(
                    'Désactivé, il disparaît des onglets de l’écran Commande. '
                    'Ses commandes passées restent.',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _busy ? null : _enregistrer,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
