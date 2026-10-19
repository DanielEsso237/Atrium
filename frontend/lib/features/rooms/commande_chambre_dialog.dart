/// Commander pour une chambre (F2.6, reunion du 18 octobre).
///
/// Le client appelle la reception depuis sa chambre : « deux bieres, s'il
/// vous plait ». La reception choisit le point de vente qui livrera, les
/// articles de sa carte, et envoie ; le bar voit la commande arriver, la
/// prepare et la monte. Rien n'est porte sur l'ardoise avant la livraison.
///
/// Un point de vente ferme -- aucun tiroir ouvert -- reste dans la liste,
/// grise : personne n'est la pour servir, le serveur refuserait la commande.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/confirmation.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/repositories/order_repository.dart' show MenuEntry;
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

/// Propose de commander pour la chambre dont `folioId` est l'ardoise.
Future<bool> showCommandeChambreDialog(
  BuildContext context, {
  required String folioId,
  required String guestName,
  required String roomNumber,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _CommandeChambre(
      folioId: folioId,
      guestName: guestName,
      roomNumber: roomNumber,
    ),
  );
  return ok ?? false;
}

class _CommandeChambre extends ConsumerStatefulWidget {
  const _CommandeChambre({
    required this.folioId,
    required this.guestName,
    required this.roomNumber,
  });

  final String folioId;
  final String guestName;
  final String roomNumber;

  @override
  ConsumerState<_CommandeChambre> createState() => _CommandeChambreState();
}

class _CommandeChambreState extends ConsumerState<_CommandeChambre> {
  String? _pointDeVente;

  /// Article -> quantite. Un article a zero n'est pas commande.
  final _quantites = <String, int>{};

  /// La precision pour le point de vente. Le controleur appartient a la
  /// fenetre : il vit tant qu'elle est a l'ecran, animation de sortie comprise.
  final _notes = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  void _choisir(String outletId) => setState(() {
    if (_pointDeVente == outletId) return;
    _pointDeVente = outletId;
    // Une autre carte : ce qui etait choisi au bar n'existe pas au grill.
    _quantites.clear();
  });

  void _changer(String articleId, int delta) => setState(() {
    final n = (_quantites[articleId] ?? 0) + delta;
    if (n <= 0) {
      _quantites.remove(articleId);
    } else {
      _quantites[articleId] = n;
    }
  });

  int _total(List<MenuEntry> carte) => [
    for (final a in carte) a.price * (_quantites[a.id] ?? 0),
  ].fold(0, (s, m) => s + m);

  Future<void> _envoyer(OutletRow pointDeVente) async {
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null || _quantites.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(roomOrderRepositoryProvider)
          .commander(
            outletId: pointDeVente.id,
            folioId: widget.folioId,
            lignes: [
              for (final e in _quantites.entries)
                (menuItemId: e.key, quantite: e.value, notes: null),
            ],
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            by: agent,
          );
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      montrerRefus(context, e.message);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
    montrerSucces(
      context,
      'Commande envoyée à ${pointDeVente.label} pour la chambre '
      '${widget.roomNumber}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final pointsDeVente =
        ref.watch(pointsDeVentePourChambreProvider).value ??
        const <(OutletRow, bool)>[];
    final choisi = pointsDeVente
        .where((e) => e.$1.id == _pointDeVente)
        .firstOrNull;
    final carte = _pointDeVente == null
        ? const <MenuEntry>[]
        : ref.watch(menuForOutletProvider(_pointDeVente!)).value ??
              const <MenuEntry>[];
    final total = _total(carte);
    final peutEnvoyer =
        choisi != null && choisi.$2 && _quantites.isNotEmpty && !_busy;

    final texte = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14,
      height: 1.45,
      color: p.textSecondary,
    );

    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.bell, size: 32),
      title: Text(
        'Commander pour la chambre ${widget.roomNumber}',
        textAlign: TextAlign.center,
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Pour ${widget.guestName}. Le point de vente prépare et monte '
                'la commande ; elle passe sur l’ardoise à la livraison.',
                style: texte,
              ),
              const SizedBox(height: 16),
              if (pointsDeVente.isEmpty)
                Text('Aucun point de vente ne livre en chambre.', style: texte)
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (o, ouvert) in pointsDeVente)
                      ChoiceChip(
                        label: Text(ouvert ? o.label : '${o.label} · fermé'),
                        selected: _pointDeVente == o.id,
                        onSelected: ouvert ? (_) => _choisir(o.id) : null,
                      ),
                  ],
                ),
              if (choisi != null) ...[
                const SizedBox(height: 18),
                if (carte.isEmpty)
                  Text('La carte de ${choisi.$1.label} est vide.', style: texte)
                else
                  for (final a in carte)
                    _LigneCarte(
                      article: a,
                      quantite: _quantites[a.id] ?? 0,
                      onMoins: () => _changer(a.id, -1),
                      onPlus: () => _changer(a.id, 1),
                    ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notes,
                  maxLength: 255,
                  decoration: const InputDecoration(
                    labelText: 'Précision pour le point de vente (facultatif)',
                    hintText: 'Bien fraîches, avec des glaçons…',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: peutEnvoyer ? () => _envoyer(choisi.$1) : null,
          child: Text(
            choisi == null
                ? 'Choisissez un point de vente'
                : total == 0
                ? 'Envoyer à ${choisi.$1.label}'
                : 'Envoyer à ${choisi.$1.label} · ${formatAmount(total)}',
          ),
        ),
      ],
    );
  }
}

/// Un article de la carte, avec sa quantite. Un article en rupture se voit
/// mais ne se choisit pas : le serveur refuserait la commande.
class _LigneCarte extends StatelessWidget {
  const _LigneCarte({
    required this.article,
    required this.quantite,
    required this.onMoins,
    required this.onPlus,
  });

  final MenuEntry article;
  final int quantite;
  final VoidCallback onMoins;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  article.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: article.isAvailable ? p.text : p.textSecondary,
                  ),
                ),
                Text(
                  article.isAvailable ? formatAmount(article.price) : 'Rupture',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13,
                    color: p.textSecondary,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Moins',
            onPressed: quantite > 0 ? onMoins : null,
            icon: const Icon(PhosphorIconsLight.minus),
          ),
          SizedBox(
            width: 28,
            child: Text(
              '$quantite',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Plus',
            onPressed: article.isAvailable ? onPlus : null,
            icon: const Icon(PhosphorIconsLight.plus),
          ),
        ],
      ),
    );
  }
}
