/// Les pieces des tableaux de bord des grands onglets -- Ventes, Stocks,
/// Entretien, Finances (demande du 18 octobre) : un meme langage d'un onglet
/// a l'autre.
///
/// - [BandeauChiffres] : le chiffre qui compte, en grand, avec son ecart a
///   la periode d'avant et sa courbe ; a cote, les chiffres qui l'expliquent.
///   C'est le seul element appuye de l'ecran, le reste se tait.
/// - [CarteSection] : un bloc, son titre, sa phrase, son contenu.
/// - [DeuxColonnes] : deux blocs cote a cote en paysage, l'un sous l'autre
///   ailleurs.
/// - [TableauAnime] : l'unique mouvement de l'ecran -- les traces se
///   dessinent a l'ouverture et a chaque changement de periode, jamais a la
///   simple mise a jour d'un chiffre.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../features/dashboard/dashboard_charts.dart' show Sparkline;
import '../tokens.dart';
import '../ui/atrium_ui.dart';
import '../ui/icons.dart';

// --- L'animation d'entree -----------------------------------------------------

/// Donne aux graphiques leurs deux temps : le trace, puis les barres.
class TableauAnime extends StatefulWidget {
  const TableauAnime({super.key, required this.builder, this.cle});

  final Widget Function(
    BuildContext context,
    Animation<double> trace,
    Animation<double> barres,
  )
  builder;

  /// Quand elle change -- une autre periode, un autre point de vente --,
  /// les traces se redessinent : la reponse au geste.
  final Object? cle;

  @override
  State<TableauAnime> createState() => _TableauAnimeState();
}

class _TableauAnimeState extends State<TableauAnime>
    with SingleTickerProviderStateMixin {
  late final _entree = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  late final _trace = CurvedAnimation(
    parent: _entree,
    curve: const Interval(0, 0.8, curve: atriumSpring),
  );
  late final _barres = CurvedAnimation(
    parent: _entree,
    curve: const Interval(0.25, 1, curve: Curves.easeOutCubic),
  );
  var _parti = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _entree.value = 1;
    } else if (!_parti) {
      _entree.forward();
    }
    _parti = true;
  }

  @override
  void didUpdateWidget(covariant TableauAnime oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cle != oldWidget.cle && !MediaQuery.disableAnimationsOf(context)) {
      _entree.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _trace.dispose();
    _barres.dispose();
    _entree.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _trace, _barres);
}

// --- Le bandeau -----------------------------------------------------------------

/// Un chiffre secondaire du bandeau.
class Mesure {
  const Mesure(
    this.libelle,
    this.valeur, {
    this.aide,
    this.alerte = false,
    this.onTap,
  });

  final String libelle;
  final String valeur;

  /// Une ligne qui dit ce que le chiffre veut dire.
  final String? aide;

  /// Le chiffre demande une action : il passe a la couleur d'alerte.
  final bool alerte;
  final VoidCallback? onTap;
}

/// Le chiffre qui compte, et ceux qui l'expliquent.
class BandeauChiffres extends StatelessWidget {
  const BandeauChiffres({
    super.key,
    required this.libelle,
    required this.valeur,
    this.variation,
    this.repere,
    this.hausseFavorable = true,
    this.courbe,
    this.descriptionCourbe = '',
    this.progres,
    this.mesures = const [],
  });

  final String libelle;
  final String valeur;

  /// L'ecart a la periode d'avant, en pour cent ; `null` sans repere.
  final int? variation;

  /// La periode d'avant, en mots : « hier », « la semaine dernière ».
  final String? repere;

  /// Une recette qui monte est une bonne nouvelle ; une depense, non.
  final bool hausseFavorable;

  /// Les derniers jours, du plus ancien au plus recent.
  final List<int>? courbe;
  final String descriptionCourbe;
  final Animation<double>? progres;
  final List<Mesure> mesures;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final heros = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          libelle,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: p.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            valeur,
            maxLines: 1,
            style: atriumDisplay(
              40,
              color: p.text,
            ).copyWith(fontFeatures: tabularFigures),
          ),
        ),
        if (variation != null || repere != null) ...[
          const SizedBox(height: 10),
          _Variation(
            variation: variation,
            repere: repere,
            hausseFavorable: hausseFavorable,
          ),
        ],
        if (courbe != null && courbe!.length > 1 && progres != null) ...[
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: Sparkline(
              valeurs: courbe!,
              couleur: AtriumChartColors.current,
              progres: progres!,
              description: descriptionCourbe,
            ),
          ),
        ],
      ],
    );

    return Bezel(
      radius: 24,
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, zone) {
          final large = zone.maxWidth >= 820;
          if (mesures.isEmpty) return heros;
          if (!large) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heros,
                const SizedBox(height: 20),
                Divider(height: 1, color: p.border),
                const SizedBox(height: 18),
                _Mesures(
                  mesures: mesures,
                  colonnes: zone.maxWidth >= 280 ? 2 : 1,
                  largeur: zone.maxWidth,
                ),
              ],
            );
          }
          // Pas de LayoutBuilder sous IntrinsicHeight : les largeurs se
          // calculent ici, une fois.
          final gauche = zone.maxWidth * 0.36;
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: gauche, child: heros),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: VerticalDivider(width: 1, color: p.border),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _Mesures(
                      mesures: mesures,
                      colonnes: mesures.length <= 4 ? 2 : 3,
                      largeur: zone.maxWidth - gauche - 49,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// L'ecart a la periode d'avant : une fleche et un pour cent dans une
/// pastille teintee, puis le repere en clair. La couleur ne dit rien seule.
class _Variation extends StatelessWidget {
  const _Variation({
    required this.variation,
    required this.repere,
    required this.hausseFavorable,
  });

  final int? variation;
  final String? repere;
  final bool hausseFavorable;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final v = variation;
    final style = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 13,
      color: p.textSecondary,
      fontFeatures: tabularFigures,
    );
    if (v == null) {
      return Text('Rien à comparer avec $repere', style: style);
    }
    final bonne = v == 0 ? null : (v > 0) == hausseFavorable;
    final couleur = bonne == null
        ? p.textSecondary
        : bonne
        ? p.success
        : p.error;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: couleur.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AtriumRadii.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (v != 0) ...[
                Icon(
                  v > 0 ? PhosphorIconsLight.trendUp : PhosphorIconsLight.trendDown,
                  size: 15,
                  color: couleur,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                '${v > 0 ? '+' : ''}$v %',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: couleur,
                  fontFeatures: tabularFigures,
                ),
              ),
            ],
          ),
        ),
        if (repere != null) Text('par rapport à $repere', style: style),
      ],
    );
  }
}

class _Mesures extends StatelessWidget {
  const _Mesures({
    required this.mesures,
    required this.colonnes,
    required this.largeur,
  });

  final List<Mesure> mesures;
  final int colonnes;

  /// La largeur disponible, mesuree par le bandeau.
  final double largeur;

  @override
  Widget build(BuildContext context) {
    const ecart = 20.0;
    final case_ = ((largeur - ecart * (colonnes - 1)) / colonnes).floorToDouble();
    return Wrap(
      spacing: ecart,
      runSpacing: 18,
      children: [
        for (final m in mesures)
          SizedBox(width: case_, child: _UneMesure(mesure: m)),
      ],
    );
  }
}

class _UneMesure extends StatelessWidget {
  const _UneMesure({required this.mesure});

  final Mesure mesure;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final m = mesure;
    final contenu = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                m.libelle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
            ),
            if (m.onTap != null) ...[
              const SizedBox(width: 4),
              Icon(
                PhosphorIconsLight.arrowUpRight,
                size: 14,
                color: p.textSecondary,
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          m.valeur,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: m.alerte ? p.error : p.text,
            fontFeatures: tabularFigures,
          ),
        ),
        if (m.aide != null) ...[
          const SizedBox(height: 2),
          Text(
            m.aide!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              color: p.textSecondary,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ],
    );
    if (m.onTap == null) return contenu;
    return InkWell(
      borderRadius: BorderRadius.circular(AtriumRadii.sm),
      onTap: m.onTap,
      child: Padding(padding: const EdgeInsets.all(2), child: contenu),
    );
  }
}

/// Les totaux d'une periode, en tete d'un historique : quelques chiffres
/// sur une ligne, sans chiffre vedette -- la liste en dessous est le sujet.
class RecapChiffres extends StatelessWidget {
  const RecapChiffres({super.key, required this.mesures});

  final List<Mesure> mesures;

  @override
  Widget build(BuildContext context) => Bezel(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
    child: LayoutBuilder(
      builder: (context, zone) {
        final colonnes = (zone.maxWidth ~/ 170).clamp(1, mesures.length);
        return _Mesures(
          mesures: mesures,
          colonnes: colonnes,
          largeur: zone.maxWidth,
        );
      },
    ),
  );
}

// --- Les blocs --------------------------------------------------------------------

/// Un bloc du tableau de bord : son titre, la phrase qui dit ce qu'il
/// montre, et en bout de titre un lien vers l'ecran qui en dit plus.
class CarteSection extends StatelessWidget {
  const CarteSection({
    super.key,
    required this.titre,
    required this.icone,
    required this.child,
    this.description,
    this.action,
    this.centrer = false,
  });

  final String titre;
  final IconData icone;
  final String? description;
  final Widget? action;
  final Widget child;

  /// Quand la rangee allonge la carte, son contenu se centre dans la
  /// hauteur gagnee au lieu de laisser tout le vide en bas : pour un
  /// graphique. Une liste garde le haut.
  final bool centrer;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 20),
      child: _CorpsDeCarte(
        centrer: centrer,
        entete: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, zone) {
                final entete = [
                  Icon(icone, size: 20, color: p.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        titre,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: p.text,
                        ),
                      ),
                    ),
                  ),
                ];
                // Etroit (telephone) : le lien passe sous le titre au lieu de
                // le pousser hors du bloc.
                if (action != null && zone.maxWidth < 420) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: entete),
                      action!,
                    ],
                  );
                }
                return Row(children: [...entete, ?action]);
              },
            ),
            if (description != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 6),
                child: Text(
                  description!,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12.5,
                    height: 1.4,
                    color: p.textSecondary,
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
        contenu: child,
      ),
    );
  }
}

/// L'en-tete d'une carte, puis son contenu : a sa hauteur naturelle, ou
/// centre dans la hauteur que la rangee lui donne.
class _CorpsDeCarte extends MultiChildRenderObjectWidget {
  _CorpsDeCarte({
    required Widget entete,
    required Widget contenu,
    required this.centrer,
  }) : super(children: [entete, contenu]);

  final bool centrer;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenduCorps(centrer: centrer);

  @override
  void updateRenderObject(BuildContext context, _RenduCorps rendu) =>
      rendu.centrer = centrer;
}

class _RenduCorps extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ParentGrille>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ParentGrille> {
  _RenduCorps({required bool centrer}) : _centrer = centrer;

  bool _centrer;
  set centrer(bool v) {
    if (v == _centrer) return;
    _centrer = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ParentGrille) child.parentData = _ParentGrille();
  }

  @override
  void performLayout() {
    final largeur = constraints.maxWidth;
    final entete = firstChild!;
    final contenu = childAfter(entete)!;
    entete.layout(BoxConstraints.tightFor(width: largeur), parentUsesSize: true);
    contenu.layout(BoxConstraints.tightFor(width: largeur), parentUsesSize: true);
    final naturel = entete.size.height + contenu.size.height;
    // Allongee par la rangee : la hauteur imposee ; sinon, la sienne.
    final hauteur = naturel > constraints.minHeight
        ? naturel
        : constraints.minHeight;
    final libre = hauteur - naturel;
    (entete.parentData! as _ParentGrille).offset = Offset.zero;
    (contenu.parentData! as _ParentGrille).offset = Offset(
      0,
      entete.size.height + (_centrer ? libre / 2 : 0),
    );
    size = constraints.constrain(Size(largeur, hauteur));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Le lien en bout de titre d'un bloc : « Tout l'historique ».
class LienSection extends StatelessWidget {
  const LienSection({
    super.key,
    required this.libelle,
    required this.onPressed,
    this.icone = PhosphorIconsLight.arrowUpRight,
  });

  final String libelle;
  final IconData icone;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    icon: Icon(icone, size: 18),
    label: Text(libelle),
  );
}

/// Deux colonnes de blocs quand la largeur le permet ; sinon tout l'un sous
/// l'autre. [flexGauche] et [flexDroite] partagent la ligne.
///
/// Les deux colonnes finissent a la meme hauteur (19 octobre : « les cartes
/// laissent de grands espaces libres ») : le dernier bloc de la plus courte
/// s'allonge jusqu'au bas de la rangee. Plus de trou sous une carte, des
/// bords alignes d'une rangee a l'autre.
class DeuxColonnes extends StatelessWidget {
  DeuxColonnes({
    super.key,
    required Widget gauche,
    required Widget droite,
    this.flexGauche = 1,
    this.flexDroite = 1,
  }) : gauches = [gauche],
       droites = [droite];

  /// Plusieurs blocs l'un sous l'autre de chaque cote.
  const DeuxColonnes.empilees({
    super.key,
    required this.gauches,
    required this.droites,
    this.flexGauche = 1,
    this.flexDroite = 1,
  });

  final List<Widget> gauches;
  final List<Widget> droites;
  final int flexGauche;
  final int flexDroite;

  @override
  Widget build(BuildContext context) => _GrilleAlignee(
    nbGauche: gauches.length,
    flexGauche: flexGauche,
    flexDroite: flexDroite,
    children: [...gauches, ...droites],
  );
}

class _GrilleAlignee extends MultiChildRenderObjectWidget {
  const _GrilleAlignee({
    required this.nbGauche,
    required this.flexGauche,
    required this.flexDroite,
    required super.children,
  });

  final int nbGauche;
  final int flexGauche;
  final int flexDroite;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenduGrille(
    nbGauche: nbGauche,
    flexGauche: flexGauche,
    flexDroite: flexDroite,
  );

  @override
  void updateRenderObject(BuildContext context, _RenduGrille rendu) {
    rendu
      ..nbGauche = nbGauche
      ..flexGauche = flexGauche
      ..flexDroite = flexDroite;
  }
}

class _ParentGrille extends ContainerBoxParentData<RenderBox> {}

/// Pose chaque bloc a sa hauteur naturelle, puis allonge le dernier de la
/// colonne la plus courte. Deux passes, sans dimensions intrinseques : les
/// graphiques mesurent leur largeur avec un LayoutBuilder, qui n'en donne
/// pas.
class _RenduGrille extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ParentGrille>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ParentGrille> {
  _RenduGrille({
    required int nbGauche,
    required int flexGauche,
    required int flexDroite,
  }) : _nbGauche = nbGauche,
       _flexGauche = flexGauche,
       _flexDroite = flexDroite;

  static const _ecart = 16.0;

  /// En dessous, tout s'empile : deux colonnes y seraient trop etroites.
  static const _seuil = 900.0;

  int _nbGauche;
  set nbGauche(int v) {
    if (v == _nbGauche) return;
    _nbGauche = v;
    markNeedsLayout();
  }

  int _flexGauche;
  set flexGauche(int v) {
    if (v == _flexGauche) return;
    _flexGauche = v;
    markNeedsLayout();
  }

  int _flexDroite;
  set flexDroite(int v) {
    if (v == _flexDroite) return;
    _flexDroite = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ParentGrille) child.parentData = _ParentGrille();
  }

  List<RenderBox> get _enfants {
    final liste = <RenderBox>[];
    var c = firstChild;
    while (c != null) {
      liste.add(c);
      c = childAfter(c);
    }
    return liste;
  }

  /// Pose les blocs d'une colonne a leur hauteur naturelle ; rend la hauteur
  /// de la colonne.
  static double _poser(List<RenderBox> colonne, double largeur) {
    var h = 0.0;
    for (final (i, e) in colonne.indexed) {
      e.layout(BoxConstraints.tightFor(width: largeur), parentUsesSize: true);
      h += e.size.height + (i > 0 ? _ecart : 0);
    }
    return h;
  }

  static void _placer(List<RenderBox> colonne, double x) {
    var y = 0.0;
    for (final e in colonne) {
      (e.parentData! as _ParentGrille).offset = Offset(x, y);
      y += e.size.height + _ecart;
    }
  }

  @override
  void performLayout() {
    final largeur = constraints.maxWidth;
    final enfants = _enfants;
    if (largeur < _seuil) {
      final h = _poser(enfants, largeur);
      _placer(enfants, 0);
      size = constraints.constrain(Size(largeur, h));
      return;
    }
    final total = _flexGauche + _flexDroite;
    final lg = ((largeur - _ecart) * _flexGauche / total).floorToDouble();
    final ld = largeur - _ecart - lg;
    final gauche = enfants.take(_nbGauche).toList();
    final droite = enfants.skip(_nbGauche).toList();
    final hg = _poser(gauche, lg);
    final hd = _poser(droite, ld);
    final h = hg > hd ? hg : hd;
    // Le dernier bloc de la colonne la plus courte descend jusqu'en bas.
    for (final (colonne, l, hc) in [(gauche, lg, hg), (droite, ld, hd)]) {
      if (colonne.isEmpty || hc >= h) continue;
      final dernier = colonne.last;
      dernier.layout(
        BoxConstraints.tightFor(
          width: l,
          height: dernier.size.height + h - hc,
        ),
        parentUsesSize: true,
      );
    }
    _placer(gauche, 0);
    _placer(droite, lg + _ecart);
    size = constraints.constrain(Size(largeur, h));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Un bloc sans rien a montrer : une phrase, pas un graphique vide.
class SectionVide extends StatelessWidget {
  const SectionVide(this.texte, {super.key});

  final String texte;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Text(
      texte,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: atriumFontFamily,
        fontSize: 14,
        color: AtriumPalette.current.textSecondary,
      ),
    ),
  );
}

/// L'ecart en pour cent entre deux periodes ; `null` sans repere (rien la
/// periode d'avant).
int? variationEnPourcent(int maintenant, int avant) =>
    avant == 0 ? null : ((maintenant - avant) * 100 / avant).round();
