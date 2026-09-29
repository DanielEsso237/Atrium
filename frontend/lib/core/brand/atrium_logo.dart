/// Le logo d'Atrium : une arche.
///
/// Un atrium est la cour ouverte au coeur d'une maison, celle sur laquelle
/// donnent toutes les pieces. L'embleme en garde la forme : une arche mangue,
/// posee sur une tuile de nuit, avec le soleil qui entre par l'ouverture.
/// Dessine en vectoriel : net sur une tablette, une icone d'onglet ou un
/// ecran de PC.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';

class AtriumMark extends StatelessWidget {
  const AtriumMark({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _ArchePainter()),
    );
  }
}

class _ArchePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final tuile = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(s * 0.28),
    );

    // La tuile : nuit profonde, un voile plus clair vers le haut.
    canvas.drawRRect(
      tuile,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF263178), Color(0xFF0A0F2E)],
        ).createShader(Offset.zero & size),
    );

    // L'arche : un U renverse, trait epais aux extremites arrondies.
    final epaisseur = s * 0.115;
    final gauche = s * 0.29;
    final droite = s * 0.71;
    final bas = s * 0.78;
    final rayon = (droite - gauche) / 2;
    final centreArc = Offset(s / 2, s * 0.30 + rayon);
    final arche = Path()
      ..moveTo(gauche, bas)
      ..lineTo(gauche, centreArc.dy)
      ..arcTo(
        Rect.fromCircle(center: centreArc, radius: rayon),
        math.pi,
        math.pi,
        false,
      )
      ..lineTo(droite, bas);
    canvas.drawPath(
      arche,
      Paint()
        ..color = const Color(0xFFFFB020)
        ..style = PaintingStyle.stroke
        ..strokeWidth = epaisseur
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Le soleil dans l'ouverture.
    canvas.drawCircle(
      Offset(s / 2, centreArc.dy + rayon * 0.05),
      s * 0.075,
      Paint()..color = const Color(0xFFFBF6EC),
    );

    // Le seuil : une ligne claire sous l'arche.
    canvas.drawLine(
      Offset(s * 0.2, bas + epaisseur * 0.95),
      Offset(s * 0.8, bas + epaisseur * 0.95),
      Paint()
        ..color = const Color(0xFFFBF6EC).withValues(alpha: 0.55)
        ..strokeWidth = s * 0.035
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Le logo et le nom, pour la barre laterale et la connexion.
class AtriumLockup extends StatelessWidget {
  const AtriumLockup({
    super.key,
    this.markSize = 40,
    this.hotelName,
    this.onNight = true,
  });

  final double markSize;
  final String? hotelName;

  /// Pose sur un fond de nuit (texte clair) ou sur le papier.
  final bool onNight;

  @override
  Widget build(BuildContext context) {
    final encre = onNight ? AtriumColors.onNight : AtriumColors.textPrimary;
    final doux = onNight ? AtriumColors.onPurpleSoft : AtriumColors.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AtriumMark(size: markSize),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Atrium',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: markSize * 0.52,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                  height: 1.05,
                  color: encre,
                ),
              ),
              if (hotelName != null)
                Text(
                  hotelName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: doux,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
