/// Les graphiques de l'ecran Rapports, un par sorte de donnee : une courbe
/// pour une tendance, des colonnes pour ce qui se compte jour par jour, un
/// anneau pour la repartition d'un tout en peu de parts, des barres
/// horizontales pour un classement, une cascade pour le benefice.
///
/// Peints a la main comme ceux du tableau de bord (`dashboard_charts.dart`) :
/// pas de bibliotheque a suivre, et la meme encre que le reste de l'ecran.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import 'export/export_model.dart' show formatPointsDeBase;

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

/// Un montant en peu de signes, pour ce qui s'ecrit sur le trace : 450 k,
/// 1,25 M. Le montant exact se lit au toucher et dans l'export.
String montantCourt(int v) {
  final signe = v < 0 ? '−' : '';
  final a = v.abs();
  if (a < 1000) return '$signe$a';
  if (a < 1000000) return '$signe${(a / 1000).round()} k';
  final m = a / 1000000;
  return '$signe${m.toStringAsFixed(m >= 10 ? 0 : 2).replaceAll('.', ',')} M';
}

TextStyle _styleLecture(AtriumPalette p) => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 12,
  fontWeight: FontWeight.w600,
  color: p.text,
  fontFeatures: tabularFigures,
);

// --- Colonnes -----------------------------------------------------------------

/// Des colonnes jour par jour, une ou deux series cote a cote.
///
/// Pour ce qui se compte chaque jour (un taux d'occupation, des arrivees) :
/// chaque jour est une quantite a part, pas un point d'une tendance. Meme
/// lecture que [CourbeRapport] : toucher une colonne l'ecrit au-dessus.
class ColonnesRapport extends StatefulWidget {
  const ColonnesRapport({
    super.key,
    required this.series,
    required this.progres,
    required this.lire,
    required this.description,
    this.plafond,
    this.etiquetteDebut,
    this.etiquetteFin,
  });

  final List<SerieCourbe> series;
  final Animation<double> progres;
  final String Function(int index) lire;
  final String description;

  /// Le haut de l'echelle quand il est connu (100 pour un taux) ; sinon le
  /// plus grand des jours.
  final int? plafond;
  final String? etiquetteDebut;
  final String? etiquetteFin;

  @override
  State<ColonnesRapport> createState() => _ColonnesRapportState();
}

class _ColonnesRapportState extends State<ColonnesRapport> {
  int? _survol;

  int get _n => widget.series.isEmpty ? 0 : widget.series.first.valeurs.length;

  void _suivre(Offset position, double largeur) {
    if (_n == 0 || largeur <= 0) return;
    final i = (position.dx / largeur * _n).floor().clamp(0, _n - 1);
    if (i != _survol) setState(() => _survol = i);
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final selection = _survol ?? (_n == 0 ? null : _n - 1);
    final legende = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 12,
      color: p.textSecondary,
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
                    style: _styleLecture(p),
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
                      painter: _PeintreColonnes(
                        series: widget.series,
                        progres: widget.progres.value,
                        survol: _survol,
                        plafond: widget.plafond,
                        grille: p.grid,
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

class _PeintreColonnes extends CustomPainter {
  _PeintreColonnes({
    required this.series,
    required this.progres,
    required this.survol,
    required this.plafond,
    required this.grille,
  });

  final List<SerieCourbe> series;
  final double progres;
  final int? survol;
  final int? plafond;
  final Color grille;

  @override
  void paint(Canvas canvas, Size size) {
    if (series.isEmpty || size.isEmpty) return;
    final n = series.first.valeurs.length;
    if (n == 0) return;
    final k = series.length;
    final maxi = math.max(
      1,
      plafond ?? [for (final s in series) ...s.valeurs].fold<int>(0, math.max),
    );
    const haut = 6.0;
    final h = size.height - haut;

    final trait = Paint()
      ..color = grille
      ..strokeWidth = 1;
    for (var j = 0; j <= 2; j++) {
      final y = haut + h * j / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), trait);
    }

    // Un jour = une case ; ses colonnes s'y centrent, 2 points entre deux
    // series, un vide entre deux jours tant que la place le permet.
    final caseL = size.width / n;
    final entreJours = caseL >= 8 ? math.max(2.0, caseL * 0.3) : 1.0;
    final entreSeries = k > 1 && caseL >= 10 ? 2.0 : 0.0;
    final col = math.min(
      22.0,
      math.max(1.0, (caseL - entreJours - entreSeries * (k - 1)) / k),
    );
    final groupe = col * k + entreSeries * (k - 1);
    final rayon = Radius.circular(math.min(4, col / 2));

    for (var i = 0; i < n; i++) {
      final x0 = caseL * i + (caseL - groupe) / 2;
      final estompe = survol != null && survol != i;
      for (var s = 0; s < k; s++) {
        final v = series[s].valeurs[i];
        if (v <= 0) continue;
        final hauteur = h * math.min(1, v / maxi) * progres;
        final x = x0 + s * (col + entreSeries);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, haut + h - hauteur, col, hauteur),
            topLeft: rayon,
            topRight: rayon,
          ),
          Paint()
            ..color = series[s].couleur.withValues(alpha: estompe ? 0.4 : 1),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PeintreColonnes old) =>
      old.progres != progres ||
      old.survol != survol ||
      old.series != series ||
      old.grille != grille;
}

// --- Anneau -------------------------------------------------------------------

/// Une part de l'anneau. Sa couleur suit l'entite (le moyen, la categorie),
/// pas son rang : d'un filtre a l'autre, les especes restent bleues.
class PartAnneau {
  const PartAnneau(this.libelle, this.valeur, this.couleur);

  final String libelle;
  final int valeur;
  final Color couleur;
}

/// La repartition d'un tout en quelques parts : l'anneau donne la
/// proportion d'un coup d'oeil, la legende ecrit chaque montant et sa part
/// -- la couleur ne porte jamais seule l'information.
///
/// Toucher une part, sur l'anneau ou dans la legende, l'ecrit au centre.
class AnneauRapport extends StatefulWidget {
  const AnneauRapport({
    super.key,
    required this.parts,
    required this.progres,
    required this.libelleTotal,
    required this.description,
    this.vide = 'Rien sur la période.',
  });

  final List<PartAnneau> parts;
  final Animation<double> progres;

  /// Ce que le centre dit du tout, sous le total (« encaissé »).
  final String libelleTotal;
  final String description;
  final String vide;

  @override
  State<AnneauRapport> createState() => _AnneauRapportState();
}

class _AnneauRapportState extends State<AnneauRapport> {
  int? _choix;

  List<PartAnneau> get _parts =>
      [for (final x in widget.parts) if (x.valeur > 0) x];

  int get _total => _parts.fold(0, (s, x) => s + x.valeur);

  void _toucher(Offset position, double cote) {
    final parts = _parts;
    if (parts.isEmpty) return;
    final d = position - Offset(cote / 2, cote / 2);
    // Le centre et l'exterieur de l'anneau ne choisissent rien.
    if (d.distance < cote * 0.28 || d.distance > cote / 2 + 6) {
      setState(() => _choix = null);
      return;
    }
    var angle = math.atan2(d.dy, d.dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    final cible = angle / (2 * math.pi) * _total;
    var cumul = 0;
    for (var i = 0; i < parts.length; i++) {
      cumul += parts[i].valeur;
      if (cible <= cumul) {
        setState(() => _choix = _choix == i ? null : i);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final parts = _parts;
    if (parts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          widget.vide,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 13,
            color: p.textSecondary,
          ),
        ),
      );
    }
    final total = _total;
    final choix = _choix != null && _choix! < parts.length ? _choix : null;

    Widget anneau(double cote) => SizedBox.square(
      dimension: cote,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _toucher(d.localPosition, cote),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: widget.progres,
              builder: (context, _) => CustomPaint(
                size: Size.square(cote),
                painter: _PeintreAnneau(
                  parts: parts,
                  progres: widget.progres.value,
                  choix: choix,
                ),
              ),
            ),
            SizedBox(
              width: cote * 0.56,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    choix == null
                        ? montantCourt(total)
                        : formatPointsDeBase(
                            (parts[choix].valeur * 10000 / total).round()),
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                      color: p.text,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                  Text(
                    choix == null ? widget.libelleTotal : parts[choix].libelle,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 11.5,
                      height: 1.25,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final legende = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < parts.length; i++)
          _LigneLegende(
            part: parts[i],
            pourcentage: formatPointsDeBase(
                (parts[i].valeur * 10000 / total).round()),
            choisie: choix == i,
            estompee: choix != null && choix != i,
            onTap: () => setState(() => _choix = _choix == i ? null : i),
          ),
      ],
    );

    return Semantics(
      label: widget.description,
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth >= 400) {
            return Row(
              children: [
                anneau(156),
                const SizedBox(width: 24),
                Expanded(child: legende),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: anneau(168)),
              const SizedBox(height: 14),
              legende,
            ],
          );
        },
      ),
    );
  }
}

class _LigneLegende extends StatelessWidget {
  const _LigneLegende({
    required this.part,
    required this.pourcentage,
    required this.choisie,
    required this.estompee,
    required this.onTap,
  });

  final PartAnneau part;
  final String pourcentage;
  final bool choisie;
  final bool estompee;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Semantics(
      button: true,
      selected: choisie,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AtriumRadii.sm),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: estompee ? 0.45 : 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: part.couleur,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      part.libelle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13.5,
                        fontWeight: choisie ? FontWeight.w700 : FontWeight.w500,
                        color: p.text,
                      ),
                    ),
                  ),
                  Text(
                    pourcentage,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 12,
                      color: p.textSecondary,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    formatAmount(part.valeur),
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PeintreAnneau extends CustomPainter {
  _PeintreAnneau({
    required this.parts,
    required this.progres,
    required this.choix,
  });

  final List<PartAnneau> parts;
  final double progres;
  final int? choix;

  @override
  void paint(Canvas canvas, Size size) {
    final total = parts.fold<int>(0, (s, x) => s + x.valeur);
    if (total == 0) return;
    const epaisseur = 20.0;
    final rayon = size.shortestSide / 2 - epaisseur / 2 - 3;
    final cadre = Rect.fromCircle(center: size.center(Offset.zero), radius: rayon);
    // Un vide de 2,5 points entre deux parts, mesure sur l'arc.
    final vide = parts.length > 1 ? 2.5 / rayon : 0.0;

    // L'anneau se trace d'un seul geste depuis midi, dans le sens des
    // aiguilles d'une montre.
    final fin = 2 * math.pi * progres;
    var debut = 0.0;
    for (var i = 0; i < parts.length; i++) {
      final balayage = 2 * math.pi * parts[i].valeur / total;
      final a = debut + vide / 2;
      final b = math.min(debut + balayage - vide / 2, fin);
      debut += balayage;
      if (b <= a) continue;
      final choisie = choix == i;
      canvas.drawArc(
        cadre,
        a - math.pi / 2,
        b - a,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = choisie ? epaisseur + 6 : epaisseur
          ..color = parts[i].couleur.withValues(
            alpha: choix != null && !choisie ? 0.35 : 1,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_PeintreAnneau old) =>
      old.progres != progres || old.choix != choix || old.parts != parts;
}

// --- Cascade ------------------------------------------------------------------

/// Un pas de la cascade : un total pose sur zero (les recettes, le
/// benefice), ou un cout retranche du total courant.
class PasCascade {
  const PasCascade(this.libelle, this.valeur, {this.total = false});

  final String libelle;

  /// Un total se lit tel quel ; un cout, en montant positif a retrancher.
  final int valeur;
  final bool total;
}

/// La cascade du benefice : des recettes, chaque cout descend d'une marche,
/// jusqu'au benefice. On y voit d'un coup d'oeil ce qui mange la marge.
///
/// Les marches tombent l'une apres l'autre a l'ouverture : c'est le seul
/// mouvement de l'ecran qui raconte quelque chose.
class CascadeRapport extends StatefulWidget {
  const CascadeRapport({
    super.key,
    required this.pas,
    required this.progres,
    required this.lire,
    required this.description,
  });

  final List<PasCascade> pas;
  final Animation<double> progres;
  final String Function(int index) lire;
  final String description;

  @override
  State<CascadeRapport> createState() => _CascadeRapportState();
}

class _CascadeRapportState extends State<CascadeRapport> {
  int? _survol;

  void _suivre(Offset position, double largeur) {
    final n = widget.pas.length;
    if (n == 0 || largeur <= 0) return;
    final i = (position.dx / largeur * n).floor().clamp(0, n - 1);
    if (i != _survol) setState(() => _survol = i);
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final n = widget.pas.length;
    final selection = _survol ?? (n == 0 ? null : n - 1);
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
                    style: _styleLecture(p),
                  ),
          ),
          const SizedBox(height: 8),
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
                      painter: _PeintreCascade(
                        pas: widget.pas,
                        progres: widget.progres.value,
                        survol: _survol,
                        palette: p,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: Text(
                    widget.pas[i].libelle,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 11.5,
                      height: 1.25,
                      fontWeight: widget.pas[i].total
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: widget.pas[i].total ? p.text : p.textSecondary,
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

class _PeintreCascade extends CustomPainter {
  _PeintreCascade({
    required this.pas,
    required this.progres,
    required this.survol,
    required this.palette,
  });

  final List<PasCascade> pas;
  final double progres;
  final int? survol;
  final AtriumPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final n = pas.length;
    if (n == 0 || size.isEmpty) return;

    // Le haut et le bas de chaque marche, le total courant entre deux.
    final marches = <(int, int)>[];
    var courant = 0;
    for (final x in pas) {
      if (x.total) {
        marches.add((0, x.valeur));
        courant = x.valeur;
      } else {
        marches.add((courant, courant - x.valeur));
        courant -= x.valeur;
      }
    }
    final bornes = [for (final (a, b) in marches) ...[a, b]];
    final maxi = math.max(1, bornes.fold<int>(0, math.max));
    final mini = math.min(0, bornes.fold<int>(0, math.min));

    // De la place au-dessus pour le montant de chaque marche, et en dessous
    // si le benefice plonge sous zero.
    const etiquette = 20.0;
    final bas = mini < 0 ? etiquette : 0.0;
    final h = size.height - etiquette - bas;
    double y(int v) => etiquette + h * (maxi - v) / (maxi - mini);

    final caseL = size.width / n;
    final largeur = math.min(64.0, caseL * 0.58);
    final zero = y(0);
    canvas.drawLine(
      Offset(0, zero),
      Offset(size.width, zero),
      Paint()
        ..color = palette.grid
        ..strokeWidth = 1,
    );

    // Chaque marche tombe a son tour : la i-eme occupe sa tranche du temps.
    double temps(int i) => (progres * (n + 1) - i).clamp(0.0, 1.0);

    final pointille = Paint()
      ..color = palette.placeholder.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var i = 0; i < n; i++) {
      final t = Curves.easeOutCubic.transform(temps(i));
      if (t == 0) continue;
      final (a, b) = marches[i];
      final x = caseL * i + (caseL - largeur) / 2;

      // Le trait qui relie le total courant a la marche suivante.
      if (i < n - 1 && temps(i + 1) > 0) {
        final niveau = y(b);
        final depart = x + largeur;
        final arrivee = caseL * (i + 1) + (caseL - largeur) / 2;
        for (var d = depart + 2; d < arrivee - 2; d += 6) {
          canvas.drawLine(
            Offset(d, niveau),
            Offset(math.min(d + 3, arrivee - 2), niveau),
            pointille,
          );
        }
      }

      final x0 = pas[i];
      final couleur = !x0.total
          ? AtriumChartColors.negatif
          : i == 0
          ? AtriumChartColors.current
          : (b < 0 ? AtriumChartColors.negatif : palette.accent);
      final estompe = survol != null && survol != i;
      // Un total pousse depuis zero ; un cout descend depuis le palier.
      final haut = y(math.max(a, b));
      final plein = y(math.min(a, b));
      final Rect rect;
      if (x0.total && b >= 0) {
        rect = Rect.fromLTRB(x, plein - (plein - haut) * t, x + largeur, plein);
      } else {
        rect = Rect.fromLTRB(x, haut, x + largeur, haut + (plein - haut) * t);
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.height < 2
              ? Rect.fromLTWH(rect.left, rect.top - 1, rect.width, 2)
              : rect,
          const Radius.circular(4),
        ),
        Paint()..color = couleur.withValues(alpha: estompe ? 0.4 : 1),
      );

      if (t >= 1) {
        final texte = x0.total ? montantCourt(b) : montantCourt(-x0.valeur);
        final peint = TextPainter(
          text: TextSpan(
            text: texte,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12,
              fontWeight: x0.total ? FontWeight.w700 : FontWeight.w600,
              color: estompe ? palette.placeholder : palette.text,
              fontFeatures: tabularFigures,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: caseL);
        final dessous = x0.total && b < 0;
        peint.paint(
          canvas,
          Offset(
            caseL * i + (caseL - peint.width) / 2,
            dessous ? plein + 4 : haut - peint.height - 4,
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PeintreCascade old) =>
      old.progres != progres ||
      old.survol != survol ||
      old.pas != pas ||
      old.palette != palette;
}
