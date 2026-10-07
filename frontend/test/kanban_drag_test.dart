import 'package:atrium/core/tokens.dart';
import 'package:atrium/core/widgets/kanban_drag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final animationsReduites in [false, true]) {
    testWidgets(
      'la sélection soulève la carte, animations réduites : $animationsReduites',
      (tester) async {
        AtriumPalette.current = AtriumPalette.light;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.linux),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: animationsReduites),
              child: child!,
            ),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 280,
                  child: KanbanDragCard<String>(
                    data: '101',
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      color: Colors.white,
                      child: const Text('Chambre 101'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final geste = await tester.startGesture(
          tester.getCenter(find.text('Chambre 101')),
        );
        await geste.moveBy(const Offset(30, 10));
        await tester.pump();
        final selection = find.byKey(const ValueKey('kanban-selection'));
        expect(selection, findsOneWidget);
        final animation = tester.widget<TweenAnimationBuilder<double>>(
          selection,
        );
        expect(
          animation.duration,
          animationsReduites
              ? Duration.zero
              : const Duration(milliseconds: 180),
        );
        await tester.pump(const Duration(milliseconds: 180));
        final zoom = tester.widget<Transform>(
          find.descendant(of: selection, matching: find.byType(Transform)).last,
        );
        expect(zoom.transform.storage[0], closeTo(1.025, 0.001));
        await geste.up();
        await tester.pumpAndSettle();
        expect(selection, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
