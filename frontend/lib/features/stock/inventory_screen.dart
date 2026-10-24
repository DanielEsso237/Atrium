/// L'inventaire d'un magasin (demande du 15 octobre).
///
/// Un tableau a quatre colonnes : l'article, ce que la machine compte (la
/// quantite theorique, figee a l'ouverture), ce que le charge d'inventaire a
/// trouve sur le terrain -- la seule colonne qui se saisit --, et l'ecart.
/// « Rééquilibrer » aligne le stock de la machine sur le terrain : un manque
/// devient une perte, un surplus un ajustement.
///
/// Deux droits (decision de Daniel) : `stock.inventory` ouvre, compte et
/// abandonne ; `stock.rebalance` reequilibre. L'un ou l'autre ouvre l'ecran.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/recherche.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/confirmation.dart';
import '../../core/ui/fenetre_motif.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/repositories/inventory_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/stock_repository.dart' show StockPlace;
import '../auth/session.dart';

const _titre = 'Inventaire';

enum _Vue { tout, aCompter, ecarts }

class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String? _magasinId;
  _Vue _vue = _Vue.tout;
  String _cherche = '';
  bool _busy = false;

  Future<void> _ouvrir(StockPlace magasin) async {
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(inventoryRepositoryProvider)
          .ouvrir(magasinId: magasin.id, by: agent);
      if (mounted) {
        montrerSucces(
          context,
          'Inventaire de ${magasin.label} ouvert : comptez, puis saisissez.',
        );
      }
    } on StateError catch (e) {
      if (mounted) montrerRefus(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reequilibrer(Inventaire inv, String magasin) async {
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null) return;
    final ecarts = inv.ecarts;
    // Dit avant la confirmation : chaque ecart doit avoir son motif.
    final sansMotif = [
      for (final l in ecarts)
        if (l.motif == null) l.productId,
    ];
    if (sansMotif.isNotEmpty) {
      final message = await ref
          .read(inventoryRepositoryProvider)
          .motifsManquants(sansMotif);
      // Le remede : la vue des ecarts, ou chaque motif se note.
      if (mounted) {
        montrerRefus(
          context,
          message,
          remede: Remede(
            'Voir les écarts',
            () => setState(() => _vue = _Vue.ecarts),
          ),
        );
      }
      return;
    }
    final manques = ecarts.where((l) => l.ecart! < 0).length;
    final surplus = ecarts.length - manques;
    final nonComptes = inv.lignes.length - inv.comptees;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogue) => AlertDialog(
        icon: const Icon(PhosphorIconsLight.scales, size: 30),
        title: Text('Rééquilibrer $magasin'),
        content: SizedBox(
          width: 460,
          child: Text(
            ecarts.isEmpty
                ? 'Aucun écart : le stock de la machine est juste. '
                      'L’inventaire se clôt sans rien changer.'
                : 'Le stock de la machine prendra les quantités comptées.\n\n'
                      '• $manques article${manques > 1 ? 's' : ''} en manque : '
                      'enregistré${manques > 1 ? 's' : ''} en perte.\n'
                      '• $surplus article${surplus > 1 ? 's' : ''} en surplus : '
                      'ajusté${surplus > 1 ? 's' : ''}.'
                      '${nonComptes == 0 ? '' : '\n\n$nonComptes article${nonComptes > 1 ? 's' : ''} non compté${nonComptes > 1 ? 's' : ''} ne bouge${nonComptes > 1 ? 'nt' : ''} pas.'}',
            style: const TextStyle(fontSize: 16),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogue).pop(false),
            child: const Text('Retour'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogue).pop(true),
            child: const Text('Rééquilibrer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final n = await ref
          .read(inventoryRepositoryProvider)
          .reequilibrer(inventaireId: inv.id, by: agent);
      if (mounted) {
        montrerSucces(
          context,
          n == 0
              ? 'Inventaire de $magasin clos : aucun écart.'
              : 'Stock de $magasin rééquilibré : $n article${n > 1 ? 's' : ''} '
                    'corrigé${n > 1 ? 's' : ''}.',
        );
      }
    } on StateError catch (e) {
      if (mounted) montrerRefus(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _abandonner(Inventaire inv) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogue) => AlertDialog(
        title: const Text('Abandonner l’inventaire'),
        content: const Text(
          'Les quantités saisies seront perdues. Le stock ne bouge pas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogue).pop(false),
            child: const Text('Retour'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogue).pop(true),
            child: const Text('Abandonner'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(inventoryRepositoryProvider).abandonner(inv.id);
    } on StateError catch (e) {
      if (mounted) montrerRefus(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final agentId = session.agent?.id;
    final peutCompter = session.acces.peut('stock.inventory');
    final peutReequilibrer = session.acces.peut('stock.rebalance');
    final magasins =
        ref.watch(stockPlacesProvider(agentId)).value ?? const <StockPlace>[];
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    if (magasins.isEmpty) {
      return const ModuleScaffold(
        title: _titre,
        body: EmptyState(
          icon: PhosphorIconsLight.archive,
          title: 'Aucun magasin',
          message:
              'Les magasins arrivent du serveur : lancez une synchronisation.',
        ),
      );
    }
    final magasin =
        magasins.where((m) => m.id == _magasinId).firstOrNull ??
        magasins.first;
    final inv = ref.watch(inventaireOuvertProvider(magasin.id)).value;

    return ModuleScaffold(
      title: _titre,
      subtitle: 'Comptez un magasin, puis alignez son stock sur le réel',
      action: inv == null
          ? (peutCompter
                ? PillButton(
                    label: 'Ouvrir l’inventaire',
                    icon: PhosphorIconsLight.checks,
                    tone: PillTone.accent,
                    onPressed: _busy ? null : () => _ouvrir(magasin),
                  )
                : null)
          : (peutReequilibrer
                ? PillButton(
                    label: 'Rééquilibrer',
                    icon: PhosphorIconsLight.scales,
                    tone: PillTone.accent,
                    onPressed: _busy || inv.comptees == 0
                        ? null
                        : () => _reequilibrer(inv, magasin.label),
                  )
                : null),
      body: ListView(
        padding: EdgeInsets.fromLTRB(marge, 0, marge, 36),
        children: [
          if (magasins.length > 1) ...[
            FilterPills<String>(
              selected: magasin.id,
              onChanged: (id) => setState(() => _magasinId = id),
              options: [for (final m in magasins) FilterOption(m.id, m.label)],
            ),
            const SizedBox(height: 14),
          ],
          if (inv == null)
            EmptyState(
              icon: PhosphorIconsLight.checks,
              title: 'Pas d’inventaire en cours pour ${magasin.label}',
              message: peutCompter
                  ? 'Ouvrez l’inventaire de préférence magasin fermé : les '
                        'quantités de la machine sont figées à l’ouverture.'
                  : 'Le chargé d’inventaire l’ouvre et compte ; vous '
                        'rééquilibrerez ensuite.',
            )
          else
            ..._tableau(inv, peutCompter),
        ],
      ),
    );
  }

  List<Widget> _tableau(Inventaire inv, bool peutCompter) {
    final p = AtriumPalette.current;
    final recherche = Recherche(_cherche);
    final lignes = [
      for (final l in inv.lignes)
        if (recherche.garde([l.libelle]) &&
            switch (_vue) {
              _Vue.tout => true,
              _Vue.aCompter => l.compte == null,
              _Vue.ecarts => l.ecart != null && l.ecart != 0,
            })
          l,
    ];
    final entete = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      color: p.textSecondary,
      letterSpacing: 0.4,
    );
    return [
      Text(
        '${inv.comptees} / ${inv.lignes.length} articles comptés · '
        '${inv.ecarts.length} écart${inv.ecarts.length > 1 ? 's' : ''}',
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: p.text,
          fontFeatures: tabularFigures,
        ),
      ),
      const SizedBox(height: 12),
      FilterPills<_Vue>(
        selected: _vue,
        onChanged: (v) => setState(() => _vue = v),
        options: [
          FilterOption(_Vue.tout, 'Tout', count: inv.lignes.length),
          FilterOption(
            _Vue.aCompter,
            'À compter',
            count: inv.lignes.length - inv.comptees,
          ),
          FilterOption(_Vue.ecarts, 'Écarts', count: inv.ecarts.length),
        ],
      ),
      const SizedBox(height: 10),
      TextField(
        onChanged: (v) => setState(() => _cherche = v),
        decoration: const InputDecoration(
          prefixIcon: Icon(PhosphorIconsLight.magnifyingGlass),
          hintText: 'Chercher un article',
        ),
      ),
      const SizedBox(height: 14),
      Bezel(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(flex: 5, child: Text('ARTICLE', style: entete)),
                Expanded(
                  flex: 2,
                  child: Text(
                    'THÉORIQUE',
                    style: entete,
                    textAlign: TextAlign.end,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'COMPTÉ',
                    style: entete,
                    textAlign: TextAlign.center,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text('ÉCART', style: entete, textAlign: TextAlign.end),
                ),
              ],
            ),
            const Divider(height: 18),
            if (lignes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Aucun article dans cette vue.',
                  style: TextStyle(color: p.textSecondary),
                ),
              ),
            for (final l in lignes)
              _Ligne(
                key: ValueKey('${inv.id}-${l.productId}'),
                inventaireId: inv.id,
                ligne: l,
                editable: peutCompter,
              ),
          ],
        ),
      ),
      if (peutCompter) ...[
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _abandonner(inv),
            icon: const Icon(PhosphorIconsLight.x),
            label: const Text('Abandonner l’inventaire'),
          ),
        ),
      ],
    ];
  }
}

/// Une ligne du tableau. La case « Compté » s'enregistre quand on la quitte
/// ou qu'on valide : pas a chaque chiffre tape.
class _Ligne extends ConsumerStatefulWidget {
  const _Ligne({
    super.key,
    required this.inventaireId,
    required this.ligne,
    required this.editable,
  });

  final String inventaireId;
  final LigneInventaire ligne;
  final bool editable;

  @override
  ConsumerState<_Ligne> createState() => _LigneState();
}

class _LigneState extends ConsumerState<_Ligne> {
  late final _compte = TextEditingController(
    text: widget.ligne.compte?.toString() ?? '',
  );
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _enregistrer();
    });
  }

  @override
  void didUpdateWidget(covariant _Ligne old) {
    super.didUpdateWidget(old);
    // Une saisie venue d'ailleurs (un autre poste) s'affiche, sauf pendant
    // qu'on tape dans la case.
    final texte = widget.ligne.compte?.toString() ?? '';
    if (!_focus.hasFocus && _compte.text != texte) _compte.text = texte;
  }

  @override
  void dispose() {
    _compte.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _enregistrer() async {
    final brut = _compte.text.trim();
    final quantite = brut.isEmpty ? null : int.tryParse(brut);
    if (brut.isNotEmpty && quantite == null) return;
    if (quantite == widget.ligne.compte) return;
    try {
      await ref
          .read(inventoryRepositoryProvider)
          .compter(
            inventaireId: widget.inventaireId,
            productId: widget.ligne.productId,
            quantite: quantite,
          );
    } on StateError catch (e) {
      if (mounted) montrerRefus(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final l = widget.ligne;
    final ecart = l.ecart;
    final couleurEcart = ecart == null || ecart == 0
        ? p.textSecondary
        : (ecart < 0 ? p.error : p.success);
    final chiffres = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 15,
      color: p.text,
      fontFeatures: tabularFigures,
    );

    final motif = l.motif;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 5,
                child: Text(
                  l.unite.isEmpty ? l.libelle : '${l.libelle} (${l.unite})',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: chiffres.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '${l.theorique}',
                  textAlign: TextAlign.end,
                  style: chiffres,
                ),
              ),
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: TextField(
                    controller: _compte,
                    focusNode: _focus,
                    enabled: widget.editable,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onSubmitted: (_) => _enregistrer(),
                    style: chiffres.copyWith(fontWeight: FontWeight.w700),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '—',
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  ecart == null ? '' : (ecart > 0 ? '+$ecart' : '$ecart'),
                  textAlign: TextAlign.end,
                  style: chiffres.copyWith(
                    fontWeight: FontWeight.w800,
                    color: couleurEcart,
                  ),
                ),
              ),
            ],
          ),
          // Le motif de l'ecart (reunion du 18 octobre) : casse, vol, erreur
          // de saisie. Seulement la ou il y a un ecart.
          if (ecart != null && ecart != 0)
            TextButton.icon(
              onPressed: widget.editable ? _noterMotif : null,
              icon: const Icon(PhosphorIconsLight.pencilSimple, size: 18),
              label: Text(
                motif == null ? 'Noter le motif de l’écart' : 'Motif : $motif',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _noterMotif() async {
    final l = widget.ligne;
    final motif = await demanderMotif(
      context,
      titre: 'Motif de l’écart : ${l.libelle}',
      libelleRenoncer: 'Fermer',
      libelleConfirmer: 'Enregistrer',
      libelleMotif: 'Motif',
      indice: 'Casse, vol, erreur de saisie, produit périmé…',
      autofocus: true,
      valeurInitiale: l.motif,
    );
    if (motif == null || !mounted) return;
    try {
      await ref
          .read(inventoryRepositoryProvider)
          .noterMotif(
            inventaireId: widget.inventaireId,
            productId: l.productId,
            motif: motif,
          );
    } on StateError catch (e) {
      if (mounted) montrerRefus(context, e.message);
    }
  }
}
