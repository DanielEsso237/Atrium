/// Selecteur a segments de la charte : une piste claire, une pastille violette
/// cerclee de menthe qui glisse sous l'option retenue.
///
/// La pastille se deplace plutot que de changer de place d'un coup : l'oeil
/// suit le mouvement et comprend quel mode vient d'etre choisi, meme sans lire
/// le libelle.
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

class AtriumSegment<T> {
  const AtriumSegment({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;
  final String label;
  final IconData icon;
}

class AtriumSegmentedControl<T> extends StatelessWidget {
  const AtriumSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<AtriumSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  static const double _hauteur = cibleTactile + 6;
  static const double _rayon = AtriumRadii.lg;

  @override
  Widget build(BuildContext context) {
    final index = segments.indexWhere((s) => s.value == selected);
    final duree = AtriumMotion.of(context, AtriumMotion.slow);

    return Container(
      height: _hauteur,
      decoration: BoxDecoration(
        color: AtriumColors.surfaceMuted,
        borderRadius: BorderRadius.circular(_rayon),
        border: Border.all(color: AtriumColors.border),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final largeur = c.maxWidth / segments.length;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedPositioned(
                duration: duree,
                curve: Curves.easeInOutCubic,
                left: largeur * index - 1,
                top: -1,
                bottom: -1,
                width: largeur + 2,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AtriumColors.purpleBright, AtriumColors.purple],
                    ),
                    borderRadius: BorderRadius.circular(_rayon),
                    border: Border.all(
                      color: AtriumColors.mintStrong,
                      width: 1.5,
                    ),
                    boxShadow: AtriumShadows.glow(
                      AtriumColors.mintStrong,
                      force: 0.35,
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final s in segments)
                    Expanded(
                      child: _Segment(
                        segment: s,
                        actif: s.value == selected,
                        duree: duree,
                        onTap: () => onChanged(s.value),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.segment,
    required this.actif,
    required this.duree,
    required this.onTap,
  });

  final AtriumSegment<T> segment;
  final bool actif;
  final Duration duree;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: actif,
      inMutuallyExclusiveGroup: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: actif ? null : onTap,
          borderRadius: BorderRadius.circular(AtriumRadii.lg),
          splashFactory: NoSplash.splashFactory,
          hoverColor: actif
              ? null
              : AtriumColors.purple.withValues(alpha: 0.04),
          focusColor: AtriumColors.mintStrong.withValues(alpha: 0.18),
          // Reduit plutot que tronque : sur un telephone de 360 points,
          // « Mot de passe » et son icone ne tiennent pas dans la moitie.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AtriumSpacing.xs),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: duree,
                      child: Icon(
                        segment.icon,
                        key: ValueKey(actif),
                        size: 20,
                        color: actif
                            ? AtriumColors.mint
                            : AtriumColors.textOnMuted,
                      ),
                    ),
                    const SizedBox(width: AtriumSpacing.xs),
                    AnimatedDefaultTextStyle(
                      duration: duree,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 15,
                        fontWeight: actif ? FontWeight.w700 : FontWeight.w600,
                        color: actif
                            ? AtriumColors.white
                            : AtriumColors.textOnMuted,
                      ),
                      child: Text(segment.label, maxLines: 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
