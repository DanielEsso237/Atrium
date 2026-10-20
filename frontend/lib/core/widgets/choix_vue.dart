/// Le choix entre deux presentations d'une meme liste -- tableau ou cartes
/// au Stock, grille ou liste au point de vente : des segments, une pastille
/// qui glisse sous celui retenu. Compact, les icones seules.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';
import '../ui/atrium_ui.dart' show atriumSpring;

class SegmentVue<T> {
  const SegmentVue(this.valeur, this.libelle, this.icone, {required this.aide});

  final T valeur;
  final String libelle;
  final IconData icone;

  /// L'infobulle : « Afficher en tableau ».
  final String aide;
}

class ChoixVue<T> extends StatelessWidget {
  const ChoixVue({
    super.key,
    required this.segments,
    required this.vue,
    required this.onChoisi,
    this.compact = false,
  });

  final List<SegmentVue<T>> segments;
  final T vue;
  final ValueChanged<T> onChoisi;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final largeur = compact ? 46.0 : 96.0;
    final rayon = BorderRadius.circular(AtriumRadii.md - 2);
    final index = segments.indexWhere((s) => s.valeur == vue);
    return Container(
      height: 44,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.paper,
        borderRadius: rayon,
        border: Border.all(color: p.border),
      ),
      child: SizedBox(
        width: largeur * segments.length,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: AtriumMotion.of(context, AtriumMotion.base),
              curve: atriumSpring,
              left: largeur * index,
              top: 0,
              bottom: 0,
              width: largeur,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.selected,
                  borderRadius: BorderRadius.circular(AtriumRadii.sm),
                ),
              ),
            ),
            Row(
              children: [
                for (final s in segments)
                  SizedBox(
                    width: largeur,
                    child: Tooltip(
                      message: s.aide,
                      child: Semantics(
                        button: true,
                        selected: s.valeur == vue,
                        label: s.libelle,
                        excludeSemantics: true,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(AtriumRadii.sm),
                          onTap: () => onChoisi(s.valeur),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  s.icone,
                                  size: 18,
                                  color: s.valeur == vue
                                      ? p.onSelected
                                      : p.textSecondary,
                                ),
                                if (!compact) ...[
                                  const SizedBox(width: 6),
                                  // Souple : une police plus large que
                                  // prevu ne fait pas deborder la case.
                                  Flexible(
                                    child: Text(
                                      s.libelle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: atriumFontFamily,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                        color: s.valeur == vue
                                            ? p.onSelected
                                            : p.text,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
