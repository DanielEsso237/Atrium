import 'package:flutter/material.dart';

import '../tokens.dart';

/// Une carte de tableau qui se souleve lorsqu'elle est selectionnee.
///
/// Le geste est immediat a la souris et precede d'un appui long sur mobile,
/// pour laisser defiler les colonnes au doigt. Les boutons de la carte
/// restent utilisables sans deplacement.
class KanbanDragCard<T extends Object> extends StatelessWidget {
  const KanbanDragCard({
    super.key,
    required this.data,
    required this.child,
    this.feedbackChild,
  });

  final T data;
  final Widget child;

  /// Le contenu souleve, sans les marges qui espacent les cartes du tableau.
  final Widget? feedbackChild;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 180));

    Widget source(double opacity, double scale) => AnimatedOpacity(
      opacity: opacity,
      duration: duree,
      child: AnimatedScale(
        scale: scale,
        duration: duree,
        curve: AtriumMotion.standard,
        child: child,
      ),
    );

    return LayoutBuilder(
      builder: (context, contraintes) {
        final apercu = SizedBox(
          width: contraintes.maxWidth,
          child: RepaintBoundary(
            child: TweenAnimationBuilder<double>(
              key: const ValueKey('kanban-selection'),
              tween: Tween(begin: 0, end: 1),
              duration: duree,
              curve: AtriumMotion.standard,
              child: feedbackChild ?? child,
              builder: (context, t, carte) => Transform.translate(
                offset: Offset(0, -6 * t),
                child: Transform.scale(
                  scale: 1 + 0.025 * t,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: p.primary, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: p.shadow.withValues(alpha: 0.12 + 0.12 * t),
                          blurRadius: 12 + 12 * t,
                          offset: Offset(0, 4 + 8 * t),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Material(
                        type: MaterialType.transparency,
                        child: carte,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final tactile = switch (Theme.of(context).platform) {
          TargetPlatform.android || TargetPlatform.iOS => true,
          _ => false,
        };
        return MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: tactile
              ? LongPressDraggable<T>(
                  data: data,
                  maxSimultaneousDrags: 1,
                  feedback: apercu,
                  childWhenDragging: source(0.35, 0.985),
                  child: source(1, 1),
                )
              : Draggable<T>(
                  data: data,
                  maxSimultaneousDrags: 1,
                  feedback: apercu,
                  childWhenDragging: source(0.35, 0.985),
                  child: source(1, 1),
                ),
        );
      },
    );
  }
}
