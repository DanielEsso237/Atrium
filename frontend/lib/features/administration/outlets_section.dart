/// Les points de vente : liste, creation, modification, desactivation.
///
/// Jamais de suppression : les commandes passees y renvoient. Desactive, un
/// point de vente sort des onglets de l'ecran Commandes et reste ici, pret a
/// etre reactive. L'ordre des onglets se regle en glissant les lignes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/repositories/outlet_repository.dart';
import '../../data/repositories/repository_providers.dart';

final _tousLesPointsDeVente = StreamProvider<List<OutletRow>>(
  (ref) => ref.watch(outletRepositoryProvider).watchAll(),
);

class OutletsSection extends ConsumerWidget {
  const OutletsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final points = ref.watch(_tousLesPointsDeVente);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 6),
          child: Row(
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
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'Chaque point de vente est un onglet de l’écran Points de vente. Glissez '
            'une ligne pour changer leur ordre.',
            style: TextStyle(
              fontSize: 13.5,
              color: AtriumPalette.current.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: points.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('Lecture impossible : $e'),
            data: (liste) => liste.isEmpty
                ? const EmptyState(
                    icon: PhosphorIconsLight.storefront,
                    title: 'Aucun point de vente',
                    message: 'Créez le restaurant, le bar, la piscine…',
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    itemCount: liste.length,
                    onReorder: (de, vers) =>
                        _reordonner(context, ref, liste, de, vers),
                    itemBuilder: (_, i) => _LignePointDeVente(
                      key: ValueKey(liste[i].id),
                      point: liste[i],
                      onTap: () => _ouvrir(context, existant: liste[i]),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _reordonner(
    BuildContext context,
    WidgetRef ref,
    List<OutletRow> liste,
    int de,
    int vers,
  ) async {
    final ordre = [...liste];
    final deplace = ordre.removeAt(de);
    ordre.insert(vers > de ? vers - 1 : vers, deplace);
    try {
      await ref.read(outletRepositoryProvider).reorder([
        for (final o in ordre) o.id,
      ]);
    } on StateError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _ouvrir(BuildContext context, {OutletRow? existant}) {
    showDialog<void>(
      context: context,
      builder: (_) => _OutletDialog(existant: existant),
    );
  }
}

class _LignePointDeVente extends StatelessWidget {
  const _LignePointDeVente({
    super.key,
    required this.point,
    required this.onTap,
  });

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
            padding: const EdgeInsets.fromLTRB(16, 16, 40, 16),
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
                        '${point.code}, $horaires',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: p.textSecondary,
                        ),
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
  late final _libelle = TextEditingController(text: widget.existant?.label);
  late TimeOfDay? _ouverture = _lire(widget.existant?.opensAt);
  late TimeOfDay? _fermeture = _lire(widget.existant?.closesAt);
  late bool _chambre = widget.existant?.allowsRoomCharge ?? true;
  late bool _actif = widget.existant?.isActive ?? true;
  bool _busy = false;

  @override
  void dispose() {
    _libelle.dispose();
    super.dispose();
  }

  static TimeOfDay? _lire(String? hhmm) {
    if (hhmm == null || !heureValide(hhmm)) return null;
    final [h, m] = hhmm.split(':');
    return TimeOfDay(hour: int.parse(h), minute: int.parse(m));
  }

  static String? _ecrire(TimeOfDay? t) => t == null
      ? null
      : '${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}';

  Future<void> _choisir(bool ouverture) async {
    final choisie = await showTimePicker(
      context: context,
      initialTime:
          (ouverture ? _ouverture : _fermeture) ??
          TimeOfDay(hour: ouverture ? 7 : 23, minute: 0),
      builder: (context, enfant) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: enfant!,
      ),
    );
    if (choisie == null) return;
    setState(() => ouverture ? _ouverture = choisie : _fermeture = choisie);
  }

  Future<void> _enregistrer() async {
    setState(() => _busy = true);
    final depot = ref.read(outletRepositoryProvider);
    final existant = widget.existant;
    try {
      if (existant == null) {
        await depot.create(
          label: _libelle.text,
          opensAt: _ecrire(_ouverture),
          closesAt: _ecrire(_fermeture),
          allowsRoomCharge: _chambre,
        );
      } else {
        await depot.update(
          id: existant.id,
          code: existant.code,
          label: _libelle.text,
          opensAt: _ecrire(_ouverture),
          closesAt: _ecrire(_fermeture),
          allowsRoomCharge: _chambre,
          sortOrder: existant.sortOrder,
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
    final existant = widget.existant;
    final creation = existant == null;
    // Le Restaurant par defaut : son activite ne se touche pas.
    final parDefaut = existant?.code == defaultOutletCode;
    final p = AtriumPalette.current;

    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.storefront, size: 30),
      title: Text(creation ? 'Nouveau point de vente' : 'Point de vente'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _libelle,
                autofocus: creation,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Libellé',
                  hintText: 'Bar, Boîte de nuit, Piscine…',
                  // Le code se deduit du libelle : l'administrateur n'a pas
                  // a l'inventer.
                  helperText: creation
                      ? 'Code : ${codeDepuisLibelle(_libelle.text)}'
                      : 'Code : ${existant.code}',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _ChampHeure(
                      libelle: 'Ouverture',
                      heure: _ecrire(_ouverture),
                      onTap: () => _choisir(true),
                      onEffacer: () => setState(() => _ouverture = null),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ChampHeure(
                      libelle: 'Fermeture',
                      heure: _ecrire(_fermeture),
                      onTap: () => _choisir(false),
                      onEffacer: () => setState(() => _fermeture = null),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Sans horaire, le point de vente est ouvert à toute heure.',
                style: TextStyle(fontSize: 12.5, color: p.textSecondary),
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
              if (!creation && !parDefaut)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _actif,
                  onChanged: (v) => setState(() => _actif = v),
                  title: const Text('Actif'),
                  subtitle: const Text(
                    'Désactivé, il disparaît des onglets de l’écran Points de vente. '
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
          onPressed: _busy || _libelle.text.trim().isEmpty
              ? null
              : _enregistrer,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

/// Un champ d'heure : on touche, une horloge s'ouvre. Pas de saisie au
/// clavier, donc pas de « 25:00 » possible.
class _ChampHeure extends StatelessWidget {
  const _ChampHeure({
    required this.libelle,
    required this.heure,
    required this.onTap,
    required this.onEffacer,
  });

  final String libelle;
  final String? heure;
  final VoidCallback onTap;
  final VoidCallback onEffacer;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: libelle,
          prefixIcon: const Icon(PhosphorIconsLight.clock, size: 20),
          suffixIcon: heure == null
              ? null
              : IconButton(
                  tooltip: 'Effacer',
                  icon: const Icon(PhosphorIconsLight.x, size: 18),
                  onPressed: onEffacer,
                ),
        ),
        child: Text(heure ?? '—', style: const TextStyle(fontSize: 17)),
      ),
    );
  }
}
