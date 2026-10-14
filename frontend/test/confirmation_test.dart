/// Le carre de succes et de refus, au milieu de l'ecran.
///
/// Demande du 14 octobre. Ce qui compte : le succes s'en va seul, le refus
/// attend « OK », et le carre ne se laisse pas fermer par le `pop` d'une
/// fiche qui se referme juste apres -- la fiche d'une chambre le fait apres
/// chaque arrivee.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/core/ui/confirmation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => AtriumPalette.current = AtriumPalette.light);

  Future<void> afficher(
    WidgetTester tester,
    void Function(BuildContext) geste,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: themeAtrium(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => geste(context),
                child: const Text('Agir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Agir'));
    await tester.pump(const Duration(milliseconds: 700));
  }

  testWidgets('le succes s\'affiche, puis s\'en va seul', (tester) async {
    await afficher(
      tester,
      (context) => montrerSucces(context, 'Réservation enregistrée.'),
    );

    expect(find.text('Réservation enregistrée.'), findsOneWidget);
    expect(find.text('OK'), findsNothing);

    await tester.pump(dureeSucces);
    await tester.pumpAndSettle();
    expect(find.text('Réservation enregistrée.'), findsNothing);
  });

  testWidgets('le refus attend OK', (tester) async {
    await afficher(
      tester,
      (context) => montrerRefus(context, 'Seuil dépassé.'),
    );

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Seuil dépassé.'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Seuil dépassé.'), findsNothing);
  });

  testWidgets('le pop d\'une fiche ne ferme pas le carre', (tester) async {
    await afficher(tester, (context) {
      showDialog<void>(
        context: context,
        builder: (fiche) => AlertDialog(
          title: const Text('Fiche'),
          actions: [
            TextButton(
              onPressed: () {
                // L'arrivee reussit, le carre s'affiche, puis la fiche se
                // ferme -- dans cet ordre, comme la fiche d'une chambre.
                montrerSucces(fiche, 'Awa est arrivée.');
                Navigator.of(fiche).pop();
              },
              child: const Text('Arrivée'),
            ),
          ],
        ),
      );
    });

    await tester.tap(find.text('Arrivée'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Fiche'), findsNothing);
    expect(find.text('Awa est arrivée.'), findsOneWidget);

    await tester.pump(dureeSucces);
    await tester.pumpAndSettle();
  });

  testWidgets('sans animation, le carre s\'affiche d\'emblee', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: themeAtrium(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => montrerRefus(context, 'Caisse fermée.'),
                child: const Text('Agir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Agir'));
    await tester.pump();

    expect(find.text('Caisse fermée.'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pump();
  });
}
