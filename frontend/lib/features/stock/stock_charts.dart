/// Les colonnes du tableau de bord des stocks (demande du 19 octobre : « des
/// graphes plus adaptes, pas de barres de progression »).
///
/// Une colonne verticale par categorie -- un magasin, un etat --, empilee
/// quand plusieurs series la composent : on compare les magasins entre eux
/// d'un coup d'oeil, et le total exact s'ecrit au-dessus de chaque colonne.
/// Toucher une colonne ecrit son detail au-dessus du trace.
///
/// Regles de la charte des graphiques : colonnes fines, extremite haute
/// arrondie a 4 points, posees sur la ligne de base ; un filet de surface de
/// 2 points entre deux segments ; quadrillage discret ; les textes restent
/// dans les encres du texte, la couleur ne porte jamais seule le sens -- la
/// legende ecrit chaque total.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/tokens.dart';

/// Une serie : son nom, sa couleur, une valeur par categorie.
class SerieEmpilee {
  const SerieEmpilee(this.libelle, this.couleur, this.valeurs);

  final String libelle;
  final Color couleur;
  final List<int> valeurs;
}

class ColonnesParCategorie extends StatefulWidget {
  const ColonnesParCategorie({
    super.key,
    required this.categories,
    required this.series,
    required this.progres,
    required this.ecrire,
    required this.lire,
    required this.description,
    this.hauteur = 230,
  });

  final List<String> categories;
  final List<SerieEmpilee> series;
  final Animation<double> progres;

  /// Le total d'une colonne, ecrit au-dessus d'elle : « 17 », « 450 k ».
  final String Function(int total) ecrire;

  /// Le detail d'une colonne touchee, en toutes lettres.
  final String Function(int index) lire;

  /// Ce que le graphique montre, pour le lecteur d'ecran.
  final String description;
  final double hauteur;

  @override
  State<ColonnesParCategorie> createState() => _ColonnesParCategorieState();
}

class _ColonnesParCategorieState extends State<ColonnesParCategorie> {
  int? _choix;

  @override
  void didUpdateWidget(covariant ColonnesParCategorie ancien) {
    super.didUpdateWidget(ancien);
    if (_choix != null && _choix! >= widget.categories.length) _choix = null;
  }

  int _index(Offset position, double largeur) {
    final n = widget.categories.length;
    return (position.dx / (largeur / n)).floor().clamp(0, n - 1);
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final n = widget.categories.length;
    final lecture = _choix == null
        ? 'Touchez une colonne pour lire son détail.'
        : widget.lire(_choix!);
    return Semantics(
      label:
          '${widget.description} : '
          '${[for (var i = 0; i < n; i++) widget.lire(i)].join('. ')}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: Text(
              lecture,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 12.5,
                fontWeight: _choix == null ? FontWeight.w400 : FontWeight.w600,
                color: _choix == null ? p.textSecondary : p.text,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: widget.hauteur,
            child: LayoutBuilder(
              builder: (context, zone) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: n == 0
                    ? null
                    : (d) {
                        final i = _index(d.localPosition, zone.maxWidth);
                        setState(() => _choix = _choix == i ? null : i);
                      },
                child: ExcludeSemantics(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size(zone.maxWidth, widget.hauteur),
                      painter: _Peintre(
                        categories: widget.categories,
                        series: widget.series,
                        progres: widget.progres,
                        ecrire: widget.ecrire,
                        choix: _choix,
                        palette: p,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Peintre extends CustomPainter {
  _Peintre({
    required this.categories,
    required this.series,
    required this.progres,
    required this.ecrire,
    required this.choix,
    required this.palette,
  }) : super(repaint: progres);

  final List<String> categories;
  final List<SerieEmpilee> series;
  final Animation<double> progres;
  final String Function(int) ecrire;
  final int? choix;
  final AtriumPalette palette;

  static const _haut = 22.0;
  static const _bas = 38.0;
  static const _ecart = 2.0;

  int _total(int i) => series.fold(0, (s, x) => s + x.valeurs[i]);

  /// Le haut de l'echelle : un chiffre rond au-dessus de la plus haute
  /// colonne (1, 2, 2,5 ou 5 fois une puissance de dix).
  static double _rond(int max) {
    if (max <= 0) return 1;
    final puissance = math.pow(10, (math.log(max) / math.ln10).floor()).toDouble();
    for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (m * puissance >= max) return m * puissance;
    }
    return 10 * puissance;
  }

  TextPainter _texte(
    String t, {
    required double taille,
    required Color couleur,
    FontWeight poids = FontWeight.w500,
    double? largeur,
    int lignes = 1,
  }) => TextPainter(
    text: TextSpan(
      text: t,
      style: TextStyle(
        fontFamily: atriumFontFamily,
        fontSize: taille,
        fontWeight: poids,
        color: couleur,
        fontFeatures: tabularFigures,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: lignes,
    ellipsis: '…',
  )..layout(maxWidth: largeur ?? double.infinity);

  @override
  void paint(Canvas canvas, Size size) {
    final n = categories.length;
    if (n == 0) return;
    final base = size.height - _bas;
    final hauteurUtile = base - _haut;
    final echelle = _rond([for (var i = 0; i < n; i++) _total(i)].reduce(math.max));

    // Le quadrillage : trois filets pleins, discrets, et la ligne de base.
    final filet = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    for (var k = 1; k <= 3; k++) {
      final y = base - hauteurUtile * k / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), filet);
    }
    canvas.drawLine(
      Offset(0, base),
      Offset(size.width, base),
      Paint()
        ..color = palette.textSecondary.withValues(alpha: 0.4)
        ..strokeWidth = 1,
    );

    final case_ = size.width / n;
    final largeur = math.min(44.0, case_ * 0.58);
    final t = progres.value.clamp(0.0, 1.0);
    for (var i = 0; i < n; i++) {
      final estompee = choix != null && choix != i;
      final centre = case_ * i + case_ / 2;
      final gauche = centre - largeur / 2;
      var haut = base;
      final segments = [
        for (final s in series)
          if (s.valeurs[i] > 0) (s.valeurs[i], s.couleur),
      ];
      for (final (k, (v, couleur)) in segments.indexed) {
        final h = hauteurUtile * v / echelle * t;
        final dernier = k == segments.length - 1;
        // Le filet de surface entre deux segments.
        final debut = k == 0 ? haut : haut - _ecart;
        final rect = Rect.fromLTRB(gauche, debut - h, gauche + largeur, debut);
        final peinture = Paint()
          ..color = estompee ? couleur.withValues(alpha: 0.3) : couleur;
        if (dernier && h > 4) {
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              rect,
              topLeft: const Radius.circular(4),
              topRight: const Radius.circular(4),
            ),
            peinture,
          );
        } else {
          canvas.drawRect(rect, peinture);
        }
        haut = debut - h;
      }

      // Le total exact au-dessus de la colonne, a la fin de la pousse.
      if (t > 0.6) {
        final total = _texte(
          ecrire(_total(i)),
          taille: 12,
          poids: FontWeight.w700,
          couleur: estompee ? palette.textSecondary : palette.text,
        );
        total.paint(
          canvas,
          Offset(centre - total.width / 2, haut - total.height - 4),
        );
      }

      // Le nom sous la colonne, sur deux lignes au plus.
      final nom = _texte(
        categories[i],
        taille: 11.5,
        couleur: choix == i ? palette.text : palette.textSecondary,
        poids: choix == i ? FontWeight.w700 : FontWeight.w500,
        largeur: case_ - 6,
        lignes: 2,
      );
      nom.paint(canvas, Offset(centre - nom.width / 2, base + 6));
    }
  }

  @override
  bool shouldRepaint(_Peintre ancien) =>
      ancien.series != series ||
      ancien.categories != categories ||
      ancien.choix != choix ||
      ancien.palette != palette;
}
