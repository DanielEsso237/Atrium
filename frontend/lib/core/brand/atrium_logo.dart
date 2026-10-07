/// Le logo Edge Hotel fourni pour l'application.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

const _logoAsset = 'assets/images/edge-hotel-logo.png';
const _logoSize = 1254.0;
const _markBounds = Rect.fromLTRB(355, 232, 900, 816);
const _nameBounds = Rect.fromLTRB(127, 864, 1122, 1055);
const _completeBounds = Rect.fromLTRB(127, 232, 1122, 1055);

// Le fichier original reste intact. Ces fenetres affichent le symbole et
// le nom a leur taille utile, sans les marges blanches de l'image fournie.
class _LogoFragment extends StatelessWidget {
  const _LogoFragment(this.bounds);

  final Rect bounds;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.contain,
    child: SizedBox(
      width: bounds.width,
      height: bounds.height,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned(
              left: -bounds.left,
              top: -bounds.top,
              width: _logoSize,
              height: _logoSize,
              child: Image.asset(
                _logoAsset,
                fit: BoxFit.fill,
                excludeFromSemantics: true,
                filterQuality: FilterQuality.high,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Le symbole du logo, pour le rail de navigation.
class AtriumMark extends StatelessWidget {
  const AtriumMark({super.key, this.size = 44, this.onNight = false});

  final double size;
  final bool onNight;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'Edge Hotel',
    child: Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(onNight ? 8 : 4),
      ),
      child: const _LogoFragment(_markBounds),
    ),
  );
}

/// Le logo complet dans sa composition officielle, symbole au-dessus du nom.
///
/// Son support evoque une porte d'hotel sans deformer l'image fournie.
class EdgeHotelLogo extends StatelessWidget {
  const EdgeHotelLogo({super.key, this.width = 232});

  final double width;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'Edge Hotel',
    child: Container(
      width: width,
      clipBehavior: Clip.antiAlias,
      padding: EdgeInsets.all(width * 0.12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(width / 2),
          topRight: Radius.circular(width / 2),
          bottomLeft: const Radius.circular(28),
          bottomRight: const Radius.circular(28),
        ),
        boxShadow: [
          BoxShadow(
            color: AtriumPalette.current.night.withValues(alpha: 0.16),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: AspectRatio(
        aspectRatio: _completeBounds.width / _completeBounds.height,
        child: const _LogoFragment(_completeBounds),
      ),
    ),
  );
}

/// Le symbole et le nom officiels, pour la navigation et la connexion.
class AtriumLockup extends StatelessWidget {
  const AtriumLockup({
    super.key,
    this.markSize = 40,
    this.hotelName,
    this.onNight = true,
    this.ink,
  });

  final Color? ink;
  final double markSize;
  final String? hotelName;
  final bool onNight;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        image: true,
        label: 'Edge Hotel',
        child: Container(
          padding: EdgeInsets.all(onNight ? 6 : 0),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: markSize,
                child: const _LogoFragment(_markBounds),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: SizedBox(
                  width: markSize * 4,
                  height: markSize * 0.8,
                  child: const _LogoFragment(_nameBounds),
                ),
              ),
            ],
          ),
        ),
      ),
      if (hotelName != null) ...[
        const SizedBox(height: 4),
        Text(
          hotelName!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: ink ?? (onNight ? Colors.white : AtriumColors.textSecondary),
          ),
        ),
      ],
    ],
  );
}
