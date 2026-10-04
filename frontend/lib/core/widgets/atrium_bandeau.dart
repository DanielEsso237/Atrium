/// Le fond des bandeaux d'en-tete : un degrade clair, la chambre de nuit qui
/// s'ouvre a droite, un voile blanc et une vague menthe.
///
/// Partage par tous les ecrans refondus : c'est ce bandeau qui fait qu'on
/// reconnait l'application d'un ecran a l'autre, comme un couloir d'hotel
/// garde la meme moquette d'un etage a l'autre.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// La photo des bandeaux et de la connexion.
const photoChambre = 'assets/images/chambre.jpg';

class AtriumBandeauFond extends StatelessWidget {
  const AtriumBandeauFond({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final telephone = c.maxWidth < 600;
        // Sur un telephone, la photo se retire a droite : pleine largeur,
        // elle passait sous le texte. Largeur arrondie au point pres : un
        // bord tombe entre deux pixels laissait un trait vertical.
        final largeurPhoto = telephone
            ? (c.maxWidth * 0.42).roundToDouble()
            : (c.maxWidth * 0.55).clamp(360.0, 820.0).roundToDouble();

        return Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AtriumDashColors.headerLight,
                      AtriumDashColors.page,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: largeurPhoto,
              // La photo devient transparente vers la gauche au lieu d'etre
              // recouverte d'un voile de couleur : un voile ne tombe jamais
              // exactement sur le degrade du fond, et laissait un trait
              // vertical la ou il commencait.
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (zone) => LinearGradient(
                  colors: [
                    AtriumColors.white.withValues(alpha: 0),
                    AtriumColors.white.withValues(alpha: telephone ? 0.3 : 0.5),
                    AtriumColors.white,
                  ],
                  stops: telephone ? const [0, 0.6, 1] : const [0, 0.3, 0.62],
                ).createShader(zone),
                child: Image.asset(
                  photoChambre,
                  fit: BoxFit.cover,
                  alignment: const Alignment(0.55, 0.1),
                  color: AtriumColors.photoTint,
                  colorBlendMode: BlendMode.multiply,
                  filterQuality: FilterQuality.medium,
                  excludeFromSemantics: true,
                ),
              ),
            ),
            const Positioned.fill(
              child: IgnorePointer(child: CustomPaint(painter: _Voiles())),
            ),
          ],
        );
      },
    );
  }
}

/// Les voiles du bandeau : une grande courbe blanche translucide qui passe
/// sur la photo, et une vague menthe au pied de l'accueil.
class _Voiles extends CustomPainter {
  const _Voiles();

  @override
  void paint(Canvas canvas, Size taille) {
    final w = taille.width;
    final h = taille.height;

    final voile = Path()
      ..moveTo(w * 0.38, 0)
      ..cubicTo(w * 0.5, h * 0.25, w * 0.52, h * 0.85, w * 0.72, h)
      ..lineTo(w * 0.3, h)
      ..lineTo(w * 0.3, 0)
      ..close();
    canvas.drawPath(
      voile,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            AtriumColors.white.withValues(alpha: 0),
            AtriumColors.white.withValues(alpha: 0.55),
          ],
        ).createShader(Rect.fromLTWH(w * 0.3, 0, w * 0.42, h)),
    );

    final menthe = Path()
      ..moveTo(0, h * 0.62)
      ..cubicTo(w * 0.1, h * 0.72, w * 0.22, h * 0.95, w * 0.34, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(
      menthe,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [
            AtriumColors.mint.withValues(alpha: 0.7),
            AtriumColors.mint.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, h * 0.6, w * 0.34, h * 0.4)),
    );
  }

  @override
  bool shouldRepaint(_Voiles ancien) => false;
}
