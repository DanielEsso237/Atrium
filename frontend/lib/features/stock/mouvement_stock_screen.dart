/// Entrer ou transférer plusieurs produits d'un coup, en plein ecran
/// (demande du 15 octobre).
///
/// Comme la fiche de vente du point de vente, a l'identique depuis le 18
/// octobre : a gauche, ce qui est deja choisi, une ligne par produit ; a
/// droite, la liste des produits et leur stock, de la meme largeur que la
/// carte du comptoir. En portrait, tout s'empile.
///
/// **La quantite se tape, elle ne se clique pas.** Toucher un produit
/// l'ajoute et met le curseur dans sa quantite, deja selectionnee, clavier
/// numerique ouvert : cent bouteilles, c'est `100`, pas cent touches. Les
/// boutons - et + ajustent d'une unite. Toucher un produit deja choisi
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
import '../orders/tableau_carte.dart' show largeurCarteFiche;

/// Ouvre l'ecran ; rend `true` si quelque chose a ete enregistre.
///
/// [ravitaillement] : le point de vente demande sa marchandise -- [magasin]
/// recoit, et l'on choisit d'ou elle vient parmi [autres]. Sinon, pour un
/// transfert, [magasin] donne vers l'un des [autres].
///
/// [entrePointsDeVente] : la marchandise vient d'un autre point de vente, pas
/// de l'economat. Le geste ne porte pas le meme nom (retour du 23 octobre) :
/// on se reapprovisionne a l'economat, on demande a un autre point de vente.
Future<bool?> ouvrirMouvementStock(
  BuildContext context, {
  required bool entree,
  required StockPlace magasin,
  List<StockPlace> autres = const [],
  bool ravitaillement = false,
  bool entrePointsDeVente = false,
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
      entrePointsDeVente: entrePointsDeVente,
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
    this.entrePointsDeVente = false,
    this.produitId,
  });

  final bool plein;

  /// Une entree (livraison, prix d'achat) ; sinon un transfert.
  final bool entree;
  final StockPlace magasin;
  final List<StockPlace> autres;
  final bool ravitaillement;
  final bool entrePointsDeVente;

  /// Un produit deja choisi : on vient de sa ligne.
  final String? produitId;

  @override
  ConsumerState<MouvementStockScreen> createState() =>
      _MouvementStockScreenState();
}

class _MouvementStockScreenState extends ConsumerState<MouvementStockScreen> {
  final _lignes = <_Ligne>[];
  final _motif = TextEditingController();
  // Un seul magasin possible -- l'economat, pour se reapprovisionner : il
  // est deja choisi, et ses produits deja la.
  late StockPlace? _autre = widget.autres.length == 1
      ? widget.autres.first
      : null;
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
    } else {
      // Toucher encore le produit en ajoute un, comme au comptoir : le
      // toucher trois fois en demandait un seul (retour du 23 octobre).
      final deja = l;
      setState(() => deja.ajouter(1));
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
        : widget.entrePointsDeVente
        ? 'Demander à un autre point de vente'
        : widget.ravitaillement
        ? 'Réapprovisionner ${widget.magasin.label}'
        : 'Réapprovisionner un point de vente';
    final unites = _lignes.fold(0, (n, l) => n + l.q);
    final valeur = _lignes.fold(0, (n, l) => n + l.q * l.pu);
    final produitsChoisis =
        '${_lignes.length} produit${_lignes.length > 1 ? 's' : ''}';
    String enUnites(int n) => '$n unité${n > 1 ? 's' : ''}';

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
          // La liste a la largeur de la carte du comptoir : la saisie, a
          // gauche, prend le reste.
          largeurCarte: largeurCarteFiche,
          contenu: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            children: [
              FicheCarte(
                titre: widget.entree
                    ? 'Livraison'
                    : widget.entrePointsDeVente
                    ? 'Transfert vers ${widget.magasin.label}'
                    : 'Réapprovisionnement',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!widget.entree) ...[
                      DropdownButtonFormField<StockPlace>(
                        initialValue: _autre,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: widget.ravitaillement
                              ? 'Depuis'
                              : 'Vers',
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        hint: const Text('Choisir le magasin'),
                        items: [
                          for (final m in widget.autres)
                            DropdownMenuItem(value: m, child: Text(m.label)),
                        ],
                        onChanged: (m) => setState(() => _autre = m),
                      ),
                      const SizedBox(height: 18),
                    ],
                    if (_lignes.isEmpty)
                      _AucuneLigne(plein: widget.plein),
                    for (final (i, l) in _lignes.indexed) ...[
                      if (i > 0) ...[
                        const SizedBox(height: 12),
                        Divider(height: 1, color: AtriumDashColors.cardBorder),
                        const SizedBox(height: 12),
                      ],
                      _LigneSaisie(
                        key: ObjectKey(l),
                        ligne: l,
                        numero: _lignes.length > 1 ? i + 1 : null,
                        entree: widget.entree,
                        disponible: enStock[l.produit.id] ?? 0,
                        depart: depart?.label,
                        onChange: () => setState(() {}),
                        onRetirer: () => _retirer(l),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FicheCarte(
                titre: widget.entree ? 'Bon de livraison' : 'Motif',
                child: TextField(
                  controller: _motif,
                  maxLength: 255,
                  decoration: InputDecoration(
                    labelText: widget.entree
                        ? 'Fournisseur, numéro du bon (facultatif)'
                        : 'Pourquoi (facultatif)',
                  ),
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
            resume: widget.entree
                ? 'À entrer, $produitsChoisis, ${enUnites(unites)}'
                : 'À transférer, $produitsChoisis',
            // Une livraison se lit en argent ; un transfert, en unites.
            nombre: widget.entree && valeur > 0 ? valeur : unites,
            format: widget.entree && valeur > 0 ? formatAmount : enUnites,
            libelle: widget.entree
                ? 'Enregistrer l’entrée'
                : widget.entrePointsDeVente
                ? 'Demander le transfert'
                : 'Réapprovisionner',
            onValider: _pret ? _valider : null,
          ),
        ),
      ),
    );
  }
}

/// Rien de choisi encore : ou toucher.
class _AucuneLigne extends StatelessWidget {
  const _AucuneLigne({required this.plein});

  final bool plein;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      decoration: BoxDecoration(
        color: p.accentTint,
        borderRadius: BorderRadius.circular(AtriumRadii.md),
      ),
      child: Row(
        children: [
          Icon(PhosphorIconsLight.package, size: 24, color: p.accent),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              plein
                  ? 'Touchez un produit dans la liste à droite pour l’ajouter.'
                  : 'Touchez un produit dans la liste ci-dessous.',
              style: TextStyle(fontSize: 15, color: p.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Une ligne choisie, comme une ligne de commande au comptoir : le produit,
/// son prix d'achat, sa quantite. Dessous, le stock du magasin.
class _LigneSaisie extends StatelessWidget {
  const _LigneSaisie({
    super.key,
    required this.ligne,
    required this.entree,
    required this.disponible,
    required this.onChange,
    required this.onRetirer,
    this.numero,
    this.depart,
  });

  final _Ligne ligne;

  /// Son rang, quand il y en a plusieurs : « Produit 2 ».
  final int? numero;
  final bool entree;

  /// Ce qu'a le magasin dont on montre le stock.
  final int disponible;
  final String? depart;
  final VoidCallback onChange;
  final VoidCallback onRetirer;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final l = ligne;
    // Seul un transfert retire du stock : une livraison ne manque de rien.
    final manque = !entree && l.q > disponible;

    final produit = InputDecorator(
      isEmpty: false,
      decoration: InputDecoration(
        labelText: numero == null ? 'Produit' : 'Produit $numero',
        floatingLabelBehavior: FloatingLabelBehavior.always,
      ),
      child: Text(
        l.produit.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
    final prix = SizedBox(
      width: 130,
      child: TextField(
        controller: l.prix,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (_) => onChange(),
        decoration: const InputDecoration(
          labelText: 'Prix d’achat',
          floatingLabelBehavior: FloatingLabelBehavior.always,
        ),
      ),
    );
    final retirer = IconButton(
      tooltip: 'Retirer ${l.produit.label}',
      icon: const Icon(PhosphorIconsLight.x, size: 20),
      onPressed: onRetirer,
    );
    final reglages = [
      if (entree) ...[prix, const SizedBox(width: 8)],
      _Quantite(ligne: l, onChange: onChange),
      retirer,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, zone) => zone.maxWidth >= 560
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: produit),
                    const SizedBox(width: 8),
                    ...reglages,
                  ],
                )
              // Etroit : le produit sur sa ligne, les reglages dessous.
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    produit,
                    const SizedBox(height: 10),
                    Row(children: reglages),
                  ],
                ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (depart != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  manque
                      ? '$depart n’en a que $disponible : son stock passera '
                            'sous zéro si le transfert est validé.'
                      : '$depart en a $disponible.',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: manque ? FontWeight.w700 : FontWeight.w500,
                    color: manque ? p.warning : p.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// La quantite, dans le cadre de la commande du comptoir, avec un champ au
/// milieu : elle se tape, - et + ajustent d'une unite. Le cadre s'allume
/// quand le curseur y est -- l'oeil sait ou va la frappe.
class _Quantite extends StatelessWidget {
  const _Quantite({required this.ligne, required this.onChange});

  final _Ligne ligne;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final l = ligne;
    void plus(int n) {
      l.ajouter(n);
      onChange();
    }

    return ListenableBuilder(
      listenable: l.focus,
      builder: (context, _) => SizedBox(
        width: 168,
        child: InputDecorator(
          isFocused: l.focus.hasFocus,
          isEmpty: false,
          decoration: InputDecoration(
            labelText: 'Quantité',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            // La hauteur des champs voisins.
            constraints: const BoxConstraints.tightFor(height: 56),
            contentPadding: const EdgeInsets.fromLTRB(2, 6, 6, 6),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Une de moins',
                iconSize: 22,
                visualDensity: VisualDensity.compact,
                icon: const Icon(PhosphorIconsLight.minusCircle),
                onPressed: l.q > 1 ? () => plus(-1) : null,
              ),
              Expanded(
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
                    fontFeatures: tabularFigures,
                  ),
                  // Sans cadre a lui : le theme en pose un sur chaque
                  // champ, le cadre de la quantite suffit.
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: '0',
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Une de plus',
                iconSize: 22,
                visualDensity: VisualDensity.compact,
                icon: const Icon(PhosphorIconsLight.plusCircle),
                onPressed: () => plus(1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La liste des produits, comme la carte du comptoir : le nom, le stock du
/// magasin de depart, et une recherche. Le prix d'achat passe sous le nom :
/// la colonne prenait la place de la saisie.
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
                const SizedBox(width: 44),
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
                      return _LigneProduit(
                        produit: x,
                        stock: widget.enStock[x.id] ?? 0,
                        prix: widget.entree ? x.purchasePrice : 0,
                        choisi: widget.choisis[x.id] ?? 0,
                        onTap: () => widget.onChoisi(x),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Une ligne de la liste, comme un article de la carte du comptoir.
class _LigneProduit extends StatelessWidget {
  const _LigneProduit({
    required this.produit,
    required this.stock,
    required this.prix,
    required this.choisi,
    required this.onTap,
  });

  final StockProduct produit;
  final int stock;

  /// Le prix d'achat, sous le nom ; 0 : on ne l'affiche pas.
  final int prix;

  /// La quantite deja choisie ; 0 : pas encore dans la saisie.
  final int choisi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      produit.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    Text(
                      prix > 0
                          ? '${produit.unit}, ${formatAmount(prix)} à l’achat'
                          : produit.unit,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: p.textSecondary,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ],
                ),
              ),
              // A zero ou dessous, en rouge : un transfert le ferait passer
              // sous zero.
              SizedBox(
                width: 90,
                child: Text(
                  '$stock',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: stock <= 0 ? p.error : p.text,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: choisi > 0
                      ? Container(
                          constraints: const BoxConstraints(minWidth: 26),
                          height: 26,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: p.accent,
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Text(
                            '$choisi',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: p.onAccent,
                              fontFeatures: tabularFigures,
                            ),
                          ),
                        )
                      : Icon(
                          PhosphorIconsLight.plus,
                          size: 18,
                          color: p.textSecondary,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// En bas, comme au comptoir : ce qui part et son total, qui glisse d'une
/// valeur a l'autre ; puis Annuler et le bouton qui enregistre tout.
class _Barre extends StatelessWidget {
  const _Barre({
    required this.resume,
    required this.nombre,
    required this.format,
    required this.libelle,
    required this.onValider,
  });

  final String resume;
  final int nombre;
  final String Function(int) format;
  final String libelle;
  final VoidCallback? onValider;

  @override
  Widget build(BuildContext context) {
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
              Expanded(
                child: Text(
                  resume,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    color: AtriumColors.textSecondary,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              TweenAnimationBuilder<double>(
                tween: Tween(end: nombre.toDouble()),
                duration: AtriumMotion.of(
                  context,
                  const Duration(milliseconds: 280),
                ),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => Text(
                  format(v.round()),
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
                flex: 2,
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
                flex: 3,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 54),
                    backgroundColor: AtriumColors.mintSoft,
                    foregroundColor: AtriumColors.ink,
                    shape: forme,
                    textStyle: texteBouton,
                  ),
                  onPressed: onValider,
                  icon: const Icon(PhosphorIconsLight.check),
                  label: Text(
                    libelle,
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
