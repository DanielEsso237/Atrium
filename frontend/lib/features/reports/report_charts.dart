/// Les graphiques de l'ecran Rapports : une courbe a une ou deux series, des
/// barres horizontales a libelle complet.
///
/// Peints a la main comme ceux du tableau de bord (`dashboard_charts.dart`) :
/// pas de bibliotheque a suivre, et la meme encre que le reste de l'ecran.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/tokens.dart';

/// Une serie de la courbe.
class SerieCourbe {
  const SerieCourbe(this.libelle, this.valeurs, this.couleur);

  final String libelle;
  final List<int> valeurs;
  final Color couleur;
}

/// Une courbe lissee, a toucher ou survoler pour lire un point.
///
/// [lire] met en mots le point retenu ; il s'affiche au-dessus du trace et
/// sert aussi de description aux lecteurs d'ecran.
class CourbeRapport extends StatefulWidget {
  const CourbeRapport({
    super.key,
    required this.series,
    required this.progres,
    required this.lire,
    required this.description,
    this.surFonce = false,
    this.remplir = true,
    this.etiquetteDebut,
    this.etiquetteFin,
  });

  final List<SerieCourbe> series;
  final Animation<double> progres;
  final String Function(int index) lire;
  final String description;
  final bool surFonce;
  final bool remplir;
  final String? etiquetteDebut;
  final String? etiquetteFin;

  @override
  State<CourbeRapport> createState() => _CourbeRapportState();
}

class _CourbeRapportState extends State<CourbeRapport> {
  int? _survol;

  int get _n => widget.series.isEmpty ? 0 : widget.series.first.valeurs.length;

  void _suivre(Offset position, double largeur) {
    if (_n < 2) return;
    final i = ((position.dx - 7) / (largeur - 14) * (_n - 1))
        .round()
        .clamp(0, _n - 1);
    if (i != _survol) setState(() => _survol = i);
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final encre = widget.surFonce ? p.onNightSoft : p.textSecondary;
    final selection = _survol ?? (_n == 0 ? null : _n - 1);
    final legende = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 12,
      color: encre,
      fontFeatures: tabularFigures,
    );

    return Semantics(
      label: widget.description,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 18,
            child: selection == null
                ? null
                : Text(
                    widget.lire(selection),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: legende.copyWith(
                      fontWeight: FontWeight.w600,
                      color: widget.surFonce ? p.onNight : p.text,
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => MouseRegion(
                onHover: (e) => _suivre(e.localPosition, c.maxWidth),
                onExit: (_) => setState(() => _survol = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _suivre(d.localPosition, c.maxWidth),
                  onHorizontalDragUpdate: (d) =>
                      _suivre(d.localPosition, c.maxWidth),
                  child: AnimatedBuilder(
                    animation: widget.progres,
                    builder: (context, _) => CustomPaint(
                      size: Size.infinite,
                      painter: _PeintreCourbe(
                        series: widget.series,
                        progres: widget.progres.value,
                        selection: selection,
                        surFonce: widget.surFonce,
                        remplir: widget.remplir,
                        grille: widget.surFonce
                            ? p.onNight.withValues(alpha: 0.12)
                            : p.grid,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.etiquetteDebut != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Text(widget.etiquetteDebut!, style: legende),
                const Spacer(),
                if (widget.etiquetteFin != null)
                  Text(widget.etiquetteFin!, style: legende),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PeintreCourbe extends CustomPainter {
  _PeintreCourbe({
    required this.series,
    required this.progres,
    required this.selection,
    required this.surFonce,
    required this.remplir,
    required this.grille,
  });

  final List<SerieCourbe> series;
  final double progres;
  final int? selection;
  final bool surFonce;
  final bool remplir;
  final Color grille;

  @override
  void paint(Canvas canvas, Size size) {
    if (series.isEmpty || size.isEmpty) return;
    final n = series.first.valeurs.length;
    final tout = [for (final s in series) ...s.valeurs];
    final maxi = math.max(1, tout.fold<int>(0, math.max));
    final mini = math.min(0, tout.fold<int>(0, math.min));
    const haut = 6.0;
    final h = size.height - haut;

    // Trois lignes de repere, sans graduation : la valeur exacte se lit au
    // toucher, et l'export porte les chiffres.
    final trait = Paint()
      ..color = grille
      ..strokeWidth = 1;
    for (var k = 0; k <= 2; k++) {
      final y = haut + h * k / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), trait);
    }

    // Une marge laterale : le point retenu au bord resterait coupe en deux.
    const cote = 7.0;
    final largeur = size.width - 2 * cote;
    Offset point(int i, int v) => Offset(
      cote + (n == 1 ? largeur / 2 : largeur * i / (n - 1)),
      haut + h - h * (v - mini) / (maxi - mini),
    );

    // Le trace se deroule de gauche a droite : une seule entree animee.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progres, size.height));
    for (var s = series.length - 1; s >= 0; s--) {
      final serie = series[s];
      final points = [
        for (var i = 0; i < n; i++) point(i, serie.valeurs[i]),
      ];
      final chemin = _lisse(points);
      if (remplir && s == 0 && n > 1) {
        final aire = Path.from(chemin)
          ..lineTo(points.last.dx, haut + h)
          ..lineTo(points.first.dx, haut + h)
          ..close();
        canvas.drawPath(
          aire,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                serie.couleur.withValues(alpha: surFonce ? 0.32 : 0.18),
                serie.couleur.withValues(alpha: 0),
              ],
            ).createShader(Offset.zero & size),
        );
      }
      canvas.drawPath(
        chemin,
        Paint()
          ..color = serie.couleur
          ..style = PaintingStyle.stroke
          ..strokeWidth = s == 0 ? 2.4 : 1.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      if (n == 1) canvas.drawCircle(points.first, 3.5, Paint()..color = serie.couleur);
    }
    canvas.restore();

    final sel = selection;
    if (sel != null && progres >= 1 && n > 1) {
      final x = point(sel, 0).dx;
      canvas.drawLine(
        Offset(x, haut),
        Offset(x, haut + h),
        Paint()
          ..color = grille.withValues(alpha: math.min(1, grille.a * 3))
          ..strokeWidth = 1,
      );
      for (final serie in series) {
        final c = point(sel, serie.valeurs[sel]);
        canvas.drawCircle(
          c,
          5,
          Paint()..color = surFonce ? AtriumPalette.current.night : Colors.white,
        );
        canvas.drawCircle(
          c,
          5,
          Paint()
            ..color = serie.couleur
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2,
        );
      }
    }
  }

  /// Une courbe qui passe par chaque point sans depasser : les tangentes
  /// sont aplaties aux extremums, sinon un creux de zero plongerait sous
  /// l'axe.
  static Path _lisse(List<Offset> p) {
    final chemin = Path()..moveTo(p.first.dx, p.first.dy);
    for (var i = 0; i < p.length - 1; i++) {
      final a = p[i];
      final b = p[i + 1];
      final dx = (b.dx - a.dx) / 3;
      // Aux extremites, la pente du seul segment voisin.
      final pente = (b.dy - a.dy) / (b.dx - a.dx);
      final ya = i == 0 ? pente : _tangente(p[i - 1], a, b);
      final yb = i + 2 >= p.length ? pente : _tangente(a, b, p[i + 2]);
      chemin.cubicTo(a.dx + dx, a.dy + ya * dx, b.dx - dx, b.dy - yb * dx, b.dx, b.dy);
    }
    return chemin;
  }

  static double _tangente(Offset avant, Offset ici, Offset apres) {
    final d1 = ici.dy - avant.dy;
    final d2 = apres.dy - ici.dy;
    if (d1 * d2 <= 0) return 0;
    return (d1 / (ici.dx - avant.dx) + d2 / (apres.dx - ici.dx)) / 2;
  }

  @override
  bool shouldRepaint(_PeintreCourbe old) =>
      old.progres != progres ||
      old.selection != selection ||
      old.series != series ||
      old.surFonce != surFonce;
}

/// Une barre de part : libelle, montant, et sa longueur relative.
class BarrePart {
  const BarrePart(this.libelle, this.valeur, this.texte, {this.detail});

  final String libelle;
  final int valeur;
  final String texte;

  /// La part en clair (« 42 % »), ou le nombre d'operations.
  final String? detail;
}

/// Des barres horizontales triees, chacune avec son libelle entier.
///
/// La couleur ne porte aucun sens a elle seule : chaque barre dit son
/// libelle et sa valeur en toutes lettres.
class BarresParts extends StatelessWidget {
  const BarresParts({
    super.key,
    required this.parts,
    required this.couleur,
    required this.progres,
    this.vide = 'Rien sur la période.',
  });

  final List<BarrePart> parts;
  final Color couleur;
  final Animation<double> progres;
  final String vide;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    if (parts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          vide,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 13,
            color: p.textSecondary,
          ),
        ),
      );
    }
    final maxi = parts.map((b) => b.valeur.abs()).fold(0, math.max);
    return AnimatedBuilder(
      animation: progres,
      builder: (context, _) => Column(
        children: [
          for (final b in parts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          b.libelle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                        ),
                      ),
                      if (b.detail != null) ...[
                        Text(
                          b.detail!,
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 12,
                            color: p.textSecondary,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Text(
                        b.texte,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: b.valeur < 0 ? p.error : p.text,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  LayoutBuilder(
                    builder: (context, c) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 8,
                        width: maxi == 0
                            ? 0
                            : math.max(
                                4,
                                c.maxWidth *
                                    b.valeur.abs() /
                                    maxi *
                                    progres.value,
                              ),
                        decoration: BoxDecoration(
                          color: b.valeur < 0 ? p.error : couleur,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
