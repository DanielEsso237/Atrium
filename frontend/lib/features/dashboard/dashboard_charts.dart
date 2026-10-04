/// Les graphiques du tableau de bord, dessines a la main.
///
/// Pas de bibliotheque de graphiques : quatre formes simples ne justifient
/// pas une dependance de plus sur une tablette hors ligne, et la maquette
/// demande des details (info-bulle, anneau espace, barres arrondies d'un seul
/// cote) qu'une bibliotheque obligerait a contourner.
///
/// Regles communes, issues de la charte des graphiques :
/// - traits de 2 points, extremites rondes ; points d'au moins 8 points avec
///   un anneau blanc pour rester lisibles sur une courbe ;
/// - aplats en voile leger sous les courbes, jamais un bloc sature ;
/// - quadrillage en filet plein, discret ;
/// - le texte reste dans les encres du texte, jamais dans la couleur d'une
///   serie : c'est la pastille a cote qui porte l'identite ;
/// - chaque graphique annonce ses valeurs au lecteur d'ecran.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/tokens.dart';
import '../../data/local/queries/dashboard_queries.dart';

// --- Outils ------------------------------------------------------------------

/// Courbe lissee qui ne depasse jamais ses points (interpolation monotone de
/// Fritsch-Carlson). Une courbe de Bezier naive ferait descendre un taux
/// d'occupation sous zero entre deux jours a 0 %.
Path courbeMonotone(List<Offset> p) {
  final chemin = Path()..moveTo(p.first.dx, p.first.dy);
  if (p.length < 3) {
    for (final point in p.skip(1)) {
      chemin.lineTo(point.dx, point.dy);
    }
    return chemin;
  }
  final n = p.length;
  final dx = [for (var i = 0; i < n - 1; i++) p[i + 1].dx - p[i].dx];
  final pente = [
    for (var i = 0; i < n - 1; i++) (p[i + 1].dy - p[i].dy) / dx[i],
  ];
  final tangente = List<double>.filled(n, 0);
  tangente[0] = pente[0];
  tangente[n - 1] = pente[n - 2];
  for (var i = 1; i < n - 1; i++) {
    if (pente[i - 1] * pente[i] <= 0) {
      tangente[i] = 0;
    } else {
      tangente[i] =
          3 *
          (dx[i - 1] + dx[i]) /
          ((2 * dx[i] + dx[i - 1]) / pente[i - 1] +
              (dx[i] + 2 * dx[i - 1]) / pente[i]);
    }
  }
  for (var i = 0; i < n - 1; i++) {
    chemin.cubicTo(
      p[i].dx + dx[i] / 3,
      p[i].dy + tangente[i] * dx[i] / 3,
      p[i + 1].dx - dx[i] / 3,
      p[i + 1].dy - tangente[i + 1] * dx[i] / 3,
      p[i + 1].dx,
      p[i + 1].dy,
    );
  }
  return chemin;
}

void _point(Canvas canvas, Offset centre, Color couleur, {double rayon = 4}) {
  canvas.drawCircle(centre, rayon + 2, Paint()..color = AtriumColors.white);
  canvas.drawCircle(centre, rayon, Paint()..color = couleur);
}

TextPainter _texte(
  String texte, {
  double taille = 12,
  FontWeight poids = FontWeight.w500,
  Color? couleur,
}) {
  couleur ??= AtriumColors.textSecondary;
  return TextPainter(
    text: TextSpan(
      text: texte,
      style: TextStyle(
        fontFamily: atriumFontFamily,
        fontSize: taille,
        fontWeight: poids,
        color: couleur,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
}

const _joursCourts = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];
const _moisCourts = [
  'janv.',
  'févr.',
  'mars',
  'avr.',
  'mai',
  'juin',
  'juil.',
  'août',
  'sept.',
  'oct.',
  'nov.',
  'déc.',
];

/// « Jeu 28 sept. »
String dateCourte(DateTime jour) =>
    '${_joursCourts[jour.weekday - 1]} ${jour.day} ${_moisCourts[jour.month - 1]}';

/// Une pastille de legende : un point de couleur et son libelle en encre.
class Legende extends StatelessWidget {
  const Legende({super.key, required this.couleur, required this.libelle});

  final Color couleur;
  final String libelle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: couleur, shape: BoxShape.circle),
        ),
        const SizedBox(width: AtriumSpacing.xs),
        Text(
          libelle,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AtriumColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

// --- Mini-courbe -------------------------------------------------------------

/// La tendance des sept derniers jours, au pied d'une carte chiffree.
///
/// Une seule serie : pas de legende, le titre de la carte dit ce qu'elle
/// trace.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.valeurs,
    required this.couleur,
    required this.progres,
    required this.description,
  });

  final List<int> valeurs;
  final Color couleur;
  final Animation<double> progres;

  /// Ce que la courbe mesure, pour le lecteur d'ecran.
  final String description;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$description sur ${valeurs.length} jours : ${valeurs.join(', ')}',
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _PeintreSparkline(valeurs, couleur, progres),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _PeintreSparkline extends CustomPainter {
  _PeintreSparkline(this.valeurs, this.couleur, this.progres)
    : super(repaint: progres);

  final List<int> valeurs;
  final Color couleur;
  final Animation<double> progres;

  @override
  void paint(Canvas canvas, Size taille) {
    if (valeurs.isEmpty) return;
    const haut = 10.0;
    const bas = 14.0;
    const gauche = 16.0;
    const droite = 14.0;
    final maximum = math.max(valeurs.reduce(math.max), 1) * 1.15;
    final pas = valeurs.length == 1
        ? 0.0
        : (taille.width - gauche - droite) / (valeurs.length - 1);
    final hauteur = taille.height - haut - bas;

    final points = [
      for (var i = 0; i < valeurs.length; i++)
        Offset(gauche + i * pas, haut + hauteur * (1 - valeurs[i] / maximum)),
    ];

    final t = progres.value.clamp(0.0, 1.0);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, taille.width * t, taille.height));

    final ligne = courbeMonotone(points);
    final aire = Path.from(ligne)
      ..lineTo(points.last.dx, taille.height)
      ..lineTo(points.first.dx, taille.height)
      ..close();
    canvas.drawPath(
      aire,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, haut),
          Offset(0, taille.height),
          [couleur.withValues(alpha: 0.28), couleur.withValues(alpha: 0.02)],
        ),
    );
    canvas.drawPath(
      ligne,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = couleur,
    );
    for (final p in points) {
      _point(canvas, p, couleur, rayon: 3);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PeintreSparkline ancien) =>
      ancien.valeurs != valeurs || ancien.couleur != couleur;
}

// --- Taux d'occupation -------------------------------------------------------

/// Deux periodes superposees : celle qui se termine aujourd'hui, et celle
/// d'avant, pour lire la tendance d'un coup d'oeil.
///
/// L'info-bulle se pose d'office sur aujourd'hui ; elle suit le doigt ou la
/// souris sur les autres jours, et revient a aujourd'hui quand on s'en va.
class OccupationChart extends StatefulWidget {
  const OccupationChart({
    super.key,
    required this.jours,
    required this.actuel,
    required this.precedent,
    required this.progres,
    required this.libelleActuel,
    required this.libellePrecedent,
  });

  final List<DateTime> jours;

  /// Taux en pourcentage entier, meme longueur que [jours].
  final List<int> actuel;
  final List<int> precedent;
  final Animation<double> progres;
  final String libelleActuel;
  final String libellePrecedent;

  @override
  State<OccupationChart> createState() => _OccupationChartState();
}

class _OccupationChartState extends State<OccupationChart> {
  int? _survol;

  static const _gauche = 44.0;
  static const _droite = 16.0;

  void _suivre(Offset position, double largeur) {
    final n = widget.jours.length;
    if (n < 2) return;
    final pas = (largeur - _gauche - _droite) / (n - 1);
    final i = ((position.dx - _gauche) / pas).round().clamp(0, n - 1);
    if (i != _survol) setState(() => _survol = i);
  }

  @override
  Widget build(BuildContext context) {
    final selection = _survol ?? widget.jours.length - 1;
    final resume = [
      for (var i = 0; i < widget.jours.length; i++)
        '${dateCourte(widget.jours[i])} ${widget.actuel[i]} %',
    ].join(', ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AtriumSpacing.lg,
          runSpacing: AtriumSpacing.xs,
          children: [
            Legende(
              couleur: AtriumChartColors.current,
              libelle: widget.libelleActuel,
            ),
            Legende(
              couleur: AtriumChartColors.previous,
              libelle: widget.libellePrecedent,
            ),
          ],
        ),
        const SizedBox(height: AtriumSpacing.sm),
        Expanded(
          child: Semantics(
            label: "Taux d'occupation, ${widget.libelleActuel} : $resume",
            child: ExcludeSemantics(
              child: LayoutBuilder(
                builder: (context, c) => MouseRegion(
                  onHover: (e) => _suivre(e.localPosition, c.maxWidth),
                  onExit: (_) => setState(() => _survol = null),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (e) => _suivre(e.localPosition, c.maxWidth),
                    onHorizontalDragUpdate: (e) =>
                        _suivre(e.localPosition, c.maxWidth),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _PeintreOccupation(
                          jours: widget.jours,
                          actuel: widget.actuel,
                          precedent: widget.precedent,
                          selection: selection,
                          progres: widget.progres,
                          libellePrecedent: widget.libellePrecedent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PeintreOccupation extends CustomPainter {
  _PeintreOccupation({
    required this.jours,
    required this.actuel,
    required this.precedent,
    required this.selection,
    required this.progres,
    required this.libellePrecedent,
  }) : super(repaint: progres);

  final List<DateTime> jours;
  final List<int> actuel;
  final List<int> precedent;
  final int selection;
  final Animation<double> progres;
  final String libellePrecedent;

  static const _gauche = _OccupationChartState._gauche;
  static const _droite = _OccupationChartState._droite;
  static const _haut = 8.0;
  static const _bas = 28.0;

  @override
  void paint(Canvas canvas, Size taille) {
    final n = jours.length;
    if (n == 0) return;
    final zone = Rect.fromLTRB(
      _gauche,
      _haut,
      taille.width - _droite,
      taille.height - _bas,
    );
    double y(num pourcent) => zone.bottom - zone.height * pourcent / 100;
    final pas = n == 1 ? 0.0 : zone.width / (n - 1);
    double x(int i) => zone.left + i * pas;

    // Quadrillage et graduations.
    final filet = Paint()
      ..color = AtriumDashColors.grid
      ..strokeWidth = 1;
    for (final v in const [0, 25, 50, 75, 100]) {
      canvas.drawLine(Offset(zone.left, y(v)), Offset(zone.right, y(v)), filet);
      final libelle = _texte('$v%');
      libelle.paint(
        canvas,
        Offset(zone.left - 10 - libelle.width, y(v) - libelle.height / 2),
      );
    }

    // Dates : toutes a sept jours, une sur deux ou sur cinq au-dela, pour
    // qu'elles ne se chevauchent jamais.
    final saut = n <= 7 ? 1 : (n <= 14 ? 2 : 5);
    for (var i = 0; i < n; i++) {
      final dernier = i == n - 1;
      if (!dernier && (n - 1 - i) % saut != 0) continue;
      final j = jours[i];
      final texte = n <= 7
          ? _joursCourts[j.weekday - 1]
          : '${j.day.toString().padLeft(2, '0')}/${j.month.toString().padLeft(2, '0')}';
      final libelle = _texte(
        texte,
        poids: i == selection ? FontWeight.w700 : FontWeight.w500,
        couleur: i == selection
            ? AtriumDashColors.title
            : AtriumColors.textSecondary,
      );
      final gauche = (x(i) - libelle.width / 2).clamp(
        0.0,
        taille.width - libelle.width,
      );
      libelle.paint(canvas, Offset(gauche, zone.bottom + 10));
    }

    final t = progres.value.clamp(0.0, 1.0);
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(0, 0, zone.left + (zone.width + 8) * t, taille.height),
    );

    void serie(List<int> valeurs, Color couleur, double voile, double trait) {
      final points = [for (var i = 0; i < n; i++) Offset(x(i), y(valeurs[i]))];
      final ligne = courbeMonotone(points);
      final aire = Path.from(ligne)
        ..lineTo(points.last.dx, zone.bottom)
        ..lineTo(points.first.dx, zone.bottom)
        ..close();
      canvas.drawPath(
        aire,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, zone.top),
            Offset(0, zone.bottom),
            [couleur.withValues(alpha: voile), couleur.withValues(alpha: 0)],
          ),
      );
      canvas.drawPath(
        ligne,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = trait
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = couleur,
      );
      for (final p in points) {
        _point(canvas, p, couleur);
      }
    }

    serie(precedent, AtriumChartColors.previous, 0.16, 2);
    serie(actuel, AtriumChartColors.current, 0.24, 2.5);
    canvas.restore();

    if (t < 1) return;

    // Info-bulle : la valeur en tete, la date en second, la periode
    // precedente en rappel.
    final sx = x(selection);
    final valeur = _texte(
      '${actuel[selection]} %',
      taille: 20,
      poids: FontWeight.w700,
      couleur: AtriumDashColors.title,
    );
    final date = _texte(dateCourte(jours[selection]), taille: 12);
    final rappel = _texte(
      'préc. ${precedent[selection]} %',
      taille: 11.5,
      poids: FontWeight.w600,
    );
    final largeur =
        math.max(math.max(valeur.width, date.width), rappel.width + 18) + 24;
    final hauteur = date.height + valeur.height + rappel.height + 22;
    final bulleGauche = (sx - largeur / 2).clamp(
      zone.left,
      zone.right - largeur,
    );
    final bulle = RRect.fromRectAndRadius(
      Rect.fromLTWH(bulleGauche, zone.top, largeur, hauteur),
      const Radius.circular(12),
    );

    // Guide pointille de la bulle au point, puis jusqu'a l'axe.
    final guide = Paint()
      ..color = AtriumDashColors.title.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var yy = bulle.bottom + 2; yy < zone.bottom; yy += 6) {
      canvas.drawLine(
        Offset(sx, yy),
        Offset(sx, math.min(yy + 3, zone.bottom)),
        guide,
      );
    }

    canvas.drawShadow(
      Path()..addRRect(bulle),
      AtriumDashColors.title.withValues(alpha: 0.25),
      6,
      false,
    );
    canvas.drawRRect(bulle, Paint()..color = AtriumColors.white);
    canvas.drawRRect(
      bulle,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = AtriumDashColors.cardBorder,
    );
    var yy = bulle.top + 8;
    date.paint(canvas, Offset(bulle.left + 12, yy));
    yy += date.height + 2;
    valeur.paint(canvas, Offset(bulle.left + 12, yy));
    yy += valeur.height + 4;
    canvas.drawLine(
      Offset(bulle.left + 12, yy + rappel.height / 2),
      Offset(bulle.left + 24, yy + rappel.height / 2),
      Paint()
        ..color = AtriumChartColors.previous
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    rappel.paint(canvas, Offset(bulle.left + 30, yy));

    _point(
      canvas,
      Offset(sx, y(actuel[selection])),
      AtriumChartColors.current,
      rayon: 5.5,
    );
    canvas.drawCircle(
      Offset(sx, zone.bottom),
      2.5,
      Paint()..color = AtriumDashColors.title,
    );
  }

  @override
  bool shouldRepaint(_PeintreOccupation ancien) =>
      ancien.selection != selection ||
      ancien.actuel != actuel ||
      ancien.precedent != precedent ||
      ancien.jours != jours;
}

// --- Repartition des chambres ------------------------------------------------

/// L'anneau des chambres par type, le nombre d'occupees au centre.
///
/// Survoler un segment ou une ligne de legende met ce type en avant et
/// affiche ses propres chiffres au centre.
class RepartitionDonut extends StatefulWidget {
  const RepartitionDonut({
    super.key,
    required this.types,
    required this.occupees,
    required this.progres,
  });

  final List<RepartitionType> types;
  final int occupees;
  final Animation<double> progres;

  @override
  State<RepartitionDonut> createState() => _RepartitionDonutState();
}

class _RepartitionDonutState extends State<RepartitionDonut> {
  int? _survol;

  /// Les types a dessiner : quatre au plus, le reste regroupe en « Autres ».
  List<(String, int, int, Color)> get _segments {
    final types = widget.types;
    final max = AtriumChartColors.types.length;
    final garde = types.take(types.length > max ? max - 1 : max).toList();
    final reste = types.skip(garde.length).toList();
    return [
      for (var i = 0; i < garde.length; i++)
        (
          garde[i].libelle,
          garde[i].total,
          garde[i].occupees,
          AtriumChartColors.types[i],
        ),
      if (reste.isNotEmpty)
        (
          'Autres',
          reste.fold(0, (s, t) => s + t.total),
          reste.fold(0, (s, t) => s + t.occupees),
          AtriumChartColors.other,
        ),
    ];
  }

  int? _segmentSous(Offset position, Size taille) {
    final centre = taille.center(Offset.zero);
    final rayon = math.min(taille.width, taille.height) / 2;
    final d = (position - centre).distance;
    if (d < rayon * 0.6 || d > rayon) return null;
    final total = _segments.fold<int>(0, (s, e) => s + e.$2);
    if (total == 0) return null;
    var angle =
        math.atan2(position.dy - centre.dy, position.dx - centre.dx) +
        math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    var cumul = 0.0;
    for (var i = 0; i < _segments.length; i++) {
      cumul += _segments[i].$2 / total * 2 * math.pi;
      if (angle <= cumul) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final segments = _segments;
    final survole = _survol != null && _survol! < segments.length
        ? segments[_survol!]
        : null;

    final anneau = LayoutBuilder(
      builder: (context, c) {
        final cote = math.min(c.maxWidth, c.maxHeight);
        return Center(
          child: SizedBox.square(
            dimension: cote,
            child: MouseRegion(
              onHover: (e) => setState(
                () =>
                    _survol = _segmentSous(e.localPosition, Size.square(cote)),
              ),
              onExit: (_) => setState(() => _survol = null),
              child: GestureDetector(
                onTapDown: (e) => setState(
                  () => _survol = _segmentSous(
                    e.localPosition,
                    Size.square(cote),
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _PeintreAnneau(
                            segments: [for (final s in segments) (s.$2, s.$4)],
                            survol: _survol,
                            progres: widget.progres,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.all(cote * 0.2),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              survole == null
                                  ? '${widget.occupees}'
                                  : '${survole.$3} / ${survole.$2}',
                              style: TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w700,
                                color: AtriumDashColors.title,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              survole == null
                                  ? 'chambres\noccupées'
                                  : '${survole.$1}\noccupées',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.35,
                                color: AtriumColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    final legende = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < segments.length; i++)
          MouseRegion(
            onEnter: (_) => setState(() => _survol = i),
            onExit: (_) => setState(() => _survol = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _survol = _survol == i ? null : i),
              child: AnimatedOpacity(
                duration: AtriumMotion.of(context, AtriumMotion.fast),
                opacity: _survol == null || _survol == i ? 1 : 0.45,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: segments[i].$4,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: AtriumSpacing.sm),
                      Expanded(
                        child: Text(
                          segments[i].$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: AtriumColors.ink,
                          ),
                        ),
                      ),
                      Text(
                        '${segments[i].$3} / ${segments[i].$2}',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AtriumColors.ink,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (segments.isEmpty) {
      return Center(
        child: Text(
          'Aucune chambre paramétrée pour le moment.',
          style: TextStyle(fontSize: 14, color: AtriumColors.textSecondary),
        ),
      );
    }

    return Semantics(
      label:
          'Répartition des chambres : ${widget.occupees} occupées. '
          '${[for (final s in segments) '${s.$1} ${s.$3} occupées sur ${s.$2}'].join(', ')}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Expanded(flex: 5, child: anneau),
            const SizedBox(width: AtriumSpacing.xl),
            Expanded(flex: 5, child: legende),
          ],
        ),
      ),
    );
  }
}

class _PeintreAnneau extends CustomPainter {
  _PeintreAnneau({
    required this.segments,
    required this.survol,
    required this.progres,
  }) : super(repaint: progres);

  final List<(int, Color)> segments;
  final int? survol;
  final Animation<double> progres;

  @override
  void paint(Canvas canvas, Size taille) {
    final rayon = math.min(taille.width, taille.height) / 2;
    final epaisseur = rayon * 0.3;
    final centre = taille.center(Offset.zero);
    final cercle = Rect.fromCircle(
      center: centre,
      radius: rayon - epaisseur / 2,
    );
    final total = segments.fold<int>(0, (s, e) => s + e.$1);

    if (total == 0) {
      canvas.drawArc(
        cercle,
        0,
        2 * math.pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = epaisseur
          ..color = AtriumDashColors.grid,
      );
      return;
    }

    // Un espace de 2 points entre deux segments, de la couleur du fond :
    // c'est lui, et non un contour, qui les separe.
    final ecart = segments.length > 1 ? 2 / (rayon - epaisseur / 2) : 0.0;
    final t = progres.value.clamp(0.0, 1.0);
    var debut = -math.pi / 2;
    final fin = -math.pi / 2 + 2 * math.pi * t;
    for (var i = 0; i < segments.length; i++) {
      final balayage = segments[i].$1 / total * 2 * math.pi;
      if (balayage <= 0) continue;
      final a = debut + ecart / 2;
      final b = math.min(debut + balayage - ecart / 2, fin);
      if (b > a) {
        final enAvant = survol == i;
        canvas.drawArc(
          enAvant ? cercle.inflate(3) : cercle,
          a,
          b - a,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = enAvant ? epaisseur + 6 : epaisseur
            ..color = survol == null || enAvant
                ? segments[i].$2
                : segments[i].$2.withValues(alpha: 0.35),
        );
      }
      debut += balayage;
    }
  }

  @override
  bool shouldRepaint(_PeintreAnneau ancien) =>
      ancien.survol != survol || ancien.segments != segments;
}

// --- Activite du jour --------------------------------------------------------

/// Arrivees et departs par tranche de trois heures.
///
/// La tranche en cours est marquee d'un fond pale : c'est la que la
/// reception regarde. Survoler une tranche donne ses deux valeurs.
class ActiviteBarres extends StatefulWidget {
  const ActiviteBarres({
    super.key,
    required this.activite,
    required this.trancheCourante,
    required this.progres,
  });

  final ActiviteHoraire activite;

  /// La tranche de l'heure actuelle, ou `null` hors de la journee affichee.
  final int? trancheCourante;
  final Animation<double> progres;

  @override
  State<ActiviteBarres> createState() => _ActiviteBarresState();
}

class _ActiviteBarresState extends State<ActiviteBarres> {
  int? _survol;

  static const _gauche = 36.0;

  void _suivre(Offset position, double largeur) {
    final n = ActiviteHoraire.tranches.length;
    final groupe = (largeur - _gauche) / n;
    final i = ((position.dx - _gauche) / groupe).floor();
    final valide = i >= 0 && i < n ? i : null;
    if (valide != _survol) setState(() => _survol = valide);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.activite;
    final resume = [
      for (var i = 0; i < ActiviteHoraire.tranches.length; i++)
        '${ActiviteHoraire.tranches[i]} h : ${a.arrivees[i]} arrivées, '
            '${a.departs[i]} départs',
    ].join(' ; ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Wrap(
          spacing: AtriumSpacing.lg,
          children: [
            Legende(couleur: AtriumChartColors.arrivals, libelle: 'Arrivées'),
            Legende(couleur: AtriumChartColors.departures, libelle: 'Départs'),
          ],
        ),
        const SizedBox(height: AtriumSpacing.sm),
        Expanded(
          child: Semantics(
            label: 'Activité du jour : $resume',
            child: ExcludeSemantics(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, c) => MouseRegion(
                        onHover: (e) => _suivre(e.localPosition, c.maxWidth),
                        onExit: (_) => setState(() => _survol = null),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (e) =>
                              _suivre(e.localPosition, c.maxWidth),
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: _PeintreBarres(
                                activite: a,
                                courante: widget.trancheCourante,
                                survol: _survol,
                                progres: widget.progres,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (a.estVide)
                    Positioned.fill(
                      left: _gauche,
                      bottom: 28,
                      child: Center(
                        child: Text(
                          'Aucune arrivée ni aucun départ enregistré aujourd’hui.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: AtriumColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PeintreBarres extends CustomPainter {
  _PeintreBarres({
    required this.activite,
    required this.courante,
    required this.survol,
    required this.progres,
  }) : super(repaint: progres);

  final ActiviteHoraire activite;
  final int? courante;
  final int? survol;
  final Animation<double> progres;

  static const _gauche = _ActiviteBarresState._gauche;
  static const _bas = 28.0;

  /// Un pas « rond » (1, 2, 5, 10, 20...) tel que trois intervalles
  /// couvrent la plus haute barre.
  static int _pas(int maximum) {
    final brut = math.max(maximum, 3) / 3;
    for (var puissance = 1; ; puissance *= 10) {
      for (final base in const [1, 2, 5]) {
        if (base * puissance >= brut) return base * puissance;
      }
    }
  }

  @override
  void paint(Canvas canvas, Size taille) {
    final n = ActiviteHoraire.tranches.length;
    final maximum = [
      ...activite.arrivees,
      ...activite.departs,
    ].reduce(math.max);
    final pas = _pas(maximum);
    final sommet = pas * 3;
    final zone = Rect.fromLTRB(_gauche, 6, taille.width, taille.height - _bas);
    double y(num v) => zone.bottom - zone.height * v / sommet;
    final groupe = zone.width / n;

    // Fond de la tranche en cours, puis de la tranche survolee.
    for (final (i, alpha) in [(courante, 0.03), (survol, 0.06)]) {
      if (i == null) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            zone.left + i * groupe + 4,
            zone.top,
            groupe - 8,
            zone.height,
          ),
          const Radius.circular(10),
        ),
        Paint()..color = AtriumDashColors.title.withValues(alpha: alpha),
      );
    }

    final filet = Paint()
      ..color = AtriumDashColors.grid
      ..strokeWidth = 1;
    for (var k = 0; k <= 3; k++) {
      final v = pas * k;
      canvas.drawLine(Offset(zone.left, y(v)), Offset(zone.right, y(v)), filet);
      final libelle = _texte('$v');
      libelle.paint(
        canvas,
        Offset(zone.left - 12 - libelle.width, y(v) - libelle.height / 2),
      );
    }

    final t = progres.value.clamp(0.0, 1.0);
    final epaisseur = math.min(18.0, groupe * 0.22);
    const espace = 6.0;
    for (var i = 0; i < n; i++) {
      final milieu = zone.left + i * groupe + groupe / 2;
      for (final (valeur, couleur, dx) in [
        (
          activite.arrivees[i],
          AtriumChartColors.arrivals,
          -espace / 2 - epaisseur,
        ),
        (activite.departs[i], AtriumChartColors.departures, espace / 2),
      ]) {
        if (valeur == 0) continue;
        final h = (zone.bottom - y(valeur)) * t;
        // Arrondi de 4 points cote donnee, carre sur la ligne de base.
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(milieu + dx, zone.bottom - h, epaisseur, h),
            topLeft: const Radius.circular(4),
            topRight: const Radius.circular(4),
          ),
          Paint()..color = couleur,
        );
      }
      final actif = i == courante || i == survol;
      final libelle = _texte(
        '${ActiviteHoraire.tranches[i]}h',
        poids: actif ? FontWeight.w700 : FontWeight.w500,
        couleur: actif ? AtriumDashColors.title : AtriumColors.textSecondary,
      );
      libelle.paint(
        canvas,
        Offset(milieu - libelle.width / 2, zone.bottom + 10),
      );
    }

    // Info-bulle de la tranche survolee : les deux series, valeurs en tete.
    final i = survol;
    if (i == null || t < 1) return;
    final debut = ActiviteHoraire.tranches[i];
    final fin = i + 1 < n ? '${ActiviteHoraire.tranches[i + 1]} h' : '6 h';
    final titre = _texte('$debut h – $fin', taille: 12);
    final lignes = [
      (activite.arrivees[i], 'arrivée', AtriumChartColors.arrivals),
      (activite.departs[i], 'départ', AtriumChartColors.departures),
    ];
    final textes = [
      for (final (v, mot, _) in lignes)
        _texte(
          '$v $mot${v > 1 ? 's' : ''}',
          taille: 13,
          poids: FontWeight.w600,
          couleur: AtriumDashColors.title,
        ),
    ];
    final largeur =
        [titre.width, ...textes.map((e) => e.width + 18)].reduce(math.max) + 24;
    final hauteur =
        titre.height + textes.fold(0.0, (s, e) => s + e.height + 4) + 16;
    final milieu = zone.left + i * groupe + groupe / 2;
    final gauche = (milieu - largeur / 2).clamp(0.0, taille.width - largeur);
    final bulle = RRect.fromRectAndRadius(
      Rect.fromLTWH(gauche, zone.top, largeur, hauteur),
      const Radius.circular(10),
    );
    canvas.drawShadow(
      Path()..addRRect(bulle),
      AtriumDashColors.title.withValues(alpha: 0.25),
      6,
      false,
    );
    canvas.drawRRect(bulle, Paint()..color = AtriumColors.white);
    var yy = bulle.top + 8;
    titre.paint(canvas, Offset(bulle.left + 12, yy));
    yy += titre.height + 4;
    for (var k = 0; k < textes.length; k++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(bulle.left + 12, yy + textes[k].height / 2 - 4, 10, 8),
          const Radius.circular(2),
        ),
        Paint()..color = lignes[k].$3,
      );
      textes[k].paint(canvas, Offset(bulle.left + 30, yy));
      yy += textes[k].height + 4;
    }
  }

  @override
  bool shouldRepaint(_PeintreBarres ancien) =>
      ancien.activite != activite ||
      ancien.courante != courante ||
      ancien.survol != survol;
}
