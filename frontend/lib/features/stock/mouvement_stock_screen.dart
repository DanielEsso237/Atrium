/// Entrer ou transférer plusieurs produits d'un coup, en plein ecran
/// (demande du 15 octobre).
///
/// Comme la fiche de vente du point de vente : a gauche, ce qui est deja
/// choisi ; a droite, la liste des produits avec leur stock et leur prix
/// d'achat. En portrait, tout s'empile.
///
/// **La quantite se tape, elle ne se clique pas.** Toucher un produit
/// l'ajoute et met le curseur dans sa quantite, deja selectionnee, clavier
/// numerique ouvert : cent bouteilles, c'est `100`, pas cent touches. Les
/// boutons − et + ajustent d'une unite. Toucher un produit deja choisi
/// ramene a sa ligne, sans doublon.
///
/// Chaque ligne part comme un mouvement a part : une entree, ou une demande
/// de transfert qui attend sa validation, comme avant.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/recherche.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/confirmation.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/fiche_laterale.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/stock_repository.dart';
import '../auth/session.dart';

/// Ouvre l'ecran ; rend `true` si quelque chose a ete enregistre.
///
/// [ravitaillement] : le point de vente demande sa marchandise -- [magasin]
/// recoit, et l'on choisit d'ou elle vient parmi [autres]. Sinon, pour un
/// transfert, [magasin] donne vers l'un des [autres].
Future<bool?> ouvrirMouvementStock(
  BuildContext context, {
  required bool entree,
  required StockPlace magasin,
  List<StockPlace> autres = const [],
  bool ravitaillement = false,
  String? produitId,
}) {
  return afficherFichePleinEcran<bool>(
    context,
    fiche: (plein) => MouvementStockScreen(
      plein: plein,
      entree: entree,
      magasin: magasin,
      autres: autres,
      ravitaillement: ravitaillement,
      produitId: produitId,
    ),
  );
}

/// Une ligne choisie : un produit, sa quantite, son prix d'achat.
class _Ligne {
  _Ligne(this.produit, {int prix = 0})
    : prix = TextEditingController(text: prix > 0 ? '$prix' : '');

  final StockProduct produit;
  final quantite = TextEditingController(text: '1');
  final TextEditingController prix;
  final focus = FocusNode();

  int get q => int.tryParse(quantite.text.trim()) ?? 0;
  int get pu => int.tryParse(prix.text.trim()) ?? 0;

  void ajouter(int n) {
    final v = (q + n).clamp(0, 999999);
    quantite.text = '$v';
  }

  void dispose() {
    quantite.dispose();
    prix.dispose();
    focus.dispose();
  }
}

class MouvementStockScreen extends ConsumerStatefulWidget {
  const MouvementStockScreen({
    super.key,
    required this.plein,
    required this.entree,
    required this.magasin,
    this.autres = const [],
    this.ravitaillement = false,
    this.produitId,
  });

  final bool plein;

  /// Une entree (livraison, prix d'achat) ; sinon un transfert.
  final bool entree;
  final StockPlace magasin;
  final List<StockPlace> autres;
  final bool ravitaillement;

  /// Un produit deja choisi : on vient de sa ligne.
  final String? produitId;

  @override
  ConsumerState<MouvementStockScreen> createState() =>
      _MouvementStockScreenState();
}

class _MouvementStockScreenState extends ConsumerState<MouvementStockScreen> {
  final _lignes = <_Ligne>[];
  final _motif = TextEditingController();
  StockPlace? _autre;
  bool _initial = false;
  bool _enCours = false;

  @override
  void dispose() {
    for (final l in _lignes) {
      l.dispose();
    }
    _motif.dispose();
    super.dispose();
  }

  /// Le magasin d'ou part la marchandise : celui dont on montre le stock.
  StockPlace? get _depart => widget.entree
      ? widget.magasin
      : widget.ravitaillement
      ? _autre
      : widget.magasin;

  void _choisir(StockProduct p) {
    var l = _lignes.where((l) => l.produit.id == p.id).firstOrNull;
    if (l == null) {
      l = _Ligne(p, prix: widget.entree ? p.purchasePrice : 0);
      setState(() => _lignes.add(l!));
    }
    final ligne = l;
    // Le curseur dans la quantite, deja selectionnee : on tape « 100 ».
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ligne.focus.requestFocus();
      ligne.quantite.selection = TextSelection(
        baseOffset: 0,
        extentOffset: ligne.quantite.text.length,
      );
    });
  }

  void _retirer(_Ligne l) => setState(() {
    _lignes.remove(l);
    l.dispose();
  });

  bool get _pret =>
      !_enCours &&
      _lignes.isNotEmpty &&
      _lignes.every((l) => l.q > 0) &&
      (widget.entree || _autre != null);

  Future<void> _valider() async {
    final depot = ref.read(stockRepositoryProvider);
    final agent = ref.read(sessionProvider).agent?.id;
    final motif = _motif.text.trim().isEmpty ? null : _motif.text.trim();
    setState(() => _enCours = true);
    var faits = 0;
    try {
      for (final l in List.of(_lignes)) {
        if (widget.entree) {
          await depot.receive(
            placeId: widget.magasin.id,
            productId: l.produit.id,
            quantity: l.q,
            unitCost: l.pu,
            reason: motif,
            by: agent,
          );
        } else {
          final source = widget.ravitaillement ? _autre! : widget.magasin;
          final cible = widget.ravitaillement ? widget.magasin : _autre!;
          await depot.requestTransfer(
            fromPlaceId: source.id,
            toPlaceId: cible.id,
            productId: l.produit.id,
            quantity: l.q,
            reason: motif,
            by: agent,
          );
        }
        // Une ligne enregistree quitte l'ecran : en cas de refus plus loin,
        // ce qui reste a l'ecran est ce qui n'est pas parti.
        faits++;
        _retirer(l);
      }
    } on StateError catch (e) {
      if (mounted) {
        setState(() => _enCours = false);
        montrerRefus(context, e.message);
      }
      return;
    }
    if (!mounted) return;
    montrerSucces(
      context,
      widget.entree
          ? '$faits produit${faits > 1 ? 's' : ''} entré${faits > 1 ? 's' : ''} '
                'à ${widget.magasin.label}.'
          : '$faits transfert${faits > 1 ? 's' : ''} demandé${faits > 1 ? 's' : ''} : '
                'ils attendent la validation du contrôleur ou du comptable.',
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final produits = ref.watch(stockProductsProvider).value ?? const [];
    final depart = _depart;
    final stock = depart == null
        ? const <StockLine>[]
        : ref
                  .watch(stockLinesProvider((placeId: depart.id, all: true)))
                  .value ??
              const <StockLine>[];
    final enStock = {for (final l in stock) l.productId: l.quantity};

    // Le produit de la ligne d'ou l'on vient, une fois la liste arrivee --
    // apres la construction : on ne change pas l'etat en pleine image.
    if (!_initial && widget.produitId != null && produits.isNotEmpty) {
      _initial = true;
      final p = produits.where((p) => p.id == widget.produitId).firstOrNull;
      if (p != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _choisir(p);
        });
      }
    }

    final titre = widget.entree
        ? 'Entrée à ${widget.magasin.label}'
        : widget.ravitaillement
        ? 'Ravitailler ${widget.magasin.label}'
        : 'Transfert depuis ${widget.magasin.label}';
    final unites = _lignes.fold(0, (n, l) => n + l.q);
    final valeur = _lignes.fold(0, (n, l) => n + l.q * l.pu);

    return FicheSurface(
      panneau: widget.plein,
      plein: widget.plein,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: miseEnPageFiche(
          plein: widget.plein,
          entete: FicheEnTete(
            panneau: widget.plein,
            retour: widget.plein,
            titre: titre,
            sousTitre: widget.entree
                ? 'Touchez les produits livrés, tapez les quantités'
                : 'Touchez les produits, tapez les quantités',
            valeur: '${_lignes.length}',
            legendeValeur: 'produit${_lignes.length > 1 ? 's' : ''}',
          ),
          contenu: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            children: [
              if (!widget.entree) ...[
                DropdownButtonFormField<StockPlace>(
                  initialValue: _autre,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: widget.ravitaillement ? 'Depuis' : 'Vers',
                  ),
                  items: [
                    for (final m in widget.autres)
                      DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: (m) => setState(() => _autre = m),
                ),
                const SizedBox(height: 16),
              ],
              if (_lignes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    widget.plein
                        ? 'Touchez un produit dans la liste pour l’ajouter.'
                        : 'Touchez un produit dans la liste ci-dessous.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: AtriumPalette.current.textSecondary,
                    ),
                  ),
                ),
              for (final l in _lignes) ...[
                _CarteLigne(
                  key: ObjectKey(l),
                  ligne: l,
                  entree: widget.entree,
                  disponible: widget.entree ? null : enStock[l.produit.id] ?? 0,
                  depart: depart?.label,
                  onChange: () => setState(() {}),
                  onRetirer: () => _retirer(l),
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 4),
              TextField(
                controller: _motif,
                maxLength: 255,
                decoration: InputDecoration(
                  labelText: widget.entree
                      ? 'Fournisseur, bon de livraison (facultatif)'
                      : 'Motif (facultatif)',
                ),
              ),
            ],
          ),
          carte: _ListeProduits(
            produits: produits,
            enStock: enStock,
            magasin: depart?.label,
            entree: widget.entree,
            choisis: {for (final l in _lignes) l.produit.id: l.q},
            onChoisi: _choisir,
          ),
          barre: _Barre(
            resume: [
              '${_lignes.length} produit${_lignes.length > 1 ? 's' : ''}',
              '$unites unité${unites > 1 ? 's' : ''}',
              if (widget.entree && valeur > 0) formatAmount(valeur),
            ].join(' · '),
            libelle: widget.entree
                ? 'Enregistrer l’entrée'
                : widget.ravitaillement
                ? 'Demander le ravitaillement'
                : 'Demander le transfert',
            onValider: _pret ? _valider : null,
          ),
        ),
      ),
    );
  }
}

/// Une ligne choisie : la quantite a taper, les colis, le prix d'achat.
class _CarteLigne extends StatelessWidget {
  const _CarteLigne({
    super.key,
    required this.ligne,
    required this.entree,
    required this.onChange,
    required this.onRetirer,
    this.disponible,
    this.depart,
  });

  final _Ligne ligne;
  final bool entree;
  final VoidCallback onChange;
  final VoidCallback onRetirer;

  /// Pour un transfert : ce qu'a le magasin de depart.
  final int? disponible;
  final String? depart;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final l = ligne;
    final manque = disponible != null && l.q > disponible!;
    void plus(int n) {
      l.ajouter(n);
      onChange();
    }

    return FicheCarte(
      titre: l.produit.label,
      suffixe: IconButton(
        tooltip: 'Retirer ${l.produit.label}',
        visualDensity: VisualDensity.compact,
        icon: const Icon(PhosphorIconsLight.x, size: 18),
        onPressed: onRetirer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton.outlined(
                tooltip: 'Une de moins',
                onPressed: l.q > 1 ? () => plus(-1) : null,
                icon: const Icon(PhosphorIconsLight.minus, size: 18),
              ),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: l.quantite,
                  focusNode: l.focus,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => onChange(),
                  onTap: () => l.quantite.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: l.quantite.text.length,
                  ),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Quantité',
                    suffixText: l.produit.unit,
                  ),
                ),
              ),
              IconButton.outlined(
                tooltip: 'Une de plus',
                onPressed: () => plus(1),
                icon: const Icon(PhosphorIconsLight.plus, size: 18),
              ),
              ],
          ),
          if (entree) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: 220,
              child: TextField(
                controller: l.prix,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => onChange(),
                decoration: const InputDecoration(
                  labelText: 'Prix d’achat unitaire',
                  suffixText: 'FCFA',
                ),
              ),
            ),
          ],
          if (disponible != null && depart != null) ...[
            const SizedBox(height: 8),
            Text(
              manque
                  ? '$depart n’en a que $disponible : son stock passera sous '
                        'zéro si le transfert est validé.'
                  : '$depart en a $disponible.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: manque ? FontWeight.w700 : FontWeight.w500,
                color: manque ? p.warning : p.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// La liste des produits : nom, stock du magasin de depart, prix d'achat,
/// et une recherche.
class _ListeProduits extends StatefulWidget {
  const _ListeProduits({
    required this.produits,
    required this.enStock,
    required this.entree,
    required this.choisis,
    required this.onChoisi,
    this.magasin,
  });

  final List<StockProduct> produits;
  final Map<String, int> enStock;
  final bool entree;

  /// La quantite deja choisie, par produit.
  final Map<String, int> choisis;
  final void Function(StockProduct) onChoisi;
  final String? magasin;

  @override
  State<_ListeProduits> createState() => _ListeProduitsState();
}

class _ListeProduitsState extends State<_ListeProduits> {
  String _cherche = '';

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final r = Recherche(_cherche);
    final produits = [
      for (final x in widget.produits)
        if (r.garde([x.label, x.unit])) x,
    ];
    final entete = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: p.textSecondary,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(
            widget.magasin == null
                ? 'Les produits'
                : 'Les produits, stock de ${widget.magasin}',
          ),
          const SizedBox(height: 12),
          SearchPill(
            hint: 'Chercher un produit…',
            onChanged: (v) => setState(() => _cherche = v),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(child: Text('Produit', style: entete)),
                SizedBox(
                  width: 90,
                  child: Text(
                    'En stock',
                    style: entete,
                    textAlign: TextAlign.center,
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: Text(
                    'Prix d’achat',
                    style: entete,
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 56),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: produits.isEmpty
                ? EmptyState(
                    icon: PhosphorIconsLight.magnifyingGlass,
                    title: widget.produits.isEmpty
                        ? 'Aucun produit'
                        : 'Rien ne correspond',
                    message: widget.produits.isEmpty
                        ? 'Les produits du stock apparaissent ici.'
                        : '« $_cherche » ne correspond à aucun produit.',
                  )
                : ListView.separated(
                    itemCount: produits.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: p.border),
                    itemBuilder: (_, i) {
                      final x = produits[i];
                      final stock = widget.enStock[x.id];
                      final choisi = widget.choisis[x.id];
                      return InkWell(
                        onTap: () => widget.onChoisi(x),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 56),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        x.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: p.text,
                                        ),
                                      ),
                                      Text(
                                        x.unit,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: p.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                    stock == null ? '0' : '$stock',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: (stock ?? 0) <= 0
                                          ? p.error
                                          : p.text,
                                      fontFeatures: tabularFigures,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 120,
                                  child: Text(
                                    x.purchasePrice > 0
                                        ? formatAmount(x.purchasePrice)
                                        : '—',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: p.text,
                                      fontFeatures: tabularFigures,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 56,
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: choisi == null
                                        ? Icon(
                                            PhosphorIconsLight.plus,
                                            size: 18,
                                            color: p.textSecondary,
                                          )
                                        : Tag('$choisi', color: p.accent),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// En bas : le resume et le bouton qui enregistre tout.
class _Barre extends StatelessWidget {
  const _Barre({
    required this.resume,
    required this.libelle,
    required this.onValider,
  });

  final String resume;
  final String libelle;
  final VoidCallback? onValider;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
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
      child: Row(
        children: [
          Expanded(
            child: Text(
              resume,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: p.text,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: onValider,
            icon: const Icon(PhosphorIconsLight.check),
            label: Text(libelle),
          ),
        ],
      ),
    );
  }
}
