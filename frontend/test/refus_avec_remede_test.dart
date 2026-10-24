/// Un refus qui attend une etape propose de la faire (demande du
/// 24 octobre) : « la caisse est fermee » propose de l'ouvrir, « il reste a
/// payer » propose d'encaisser.
library;

import 'package:atrium/core/ui/confirmation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> ouvrir(WidgetTester tester, {Remede? remede}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => montrerRefus(c, 'Il reste 5 000 FCFA à payer.',
                remede: remede),
            child: const Text('geste'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('geste'));
    await tester.pumpAndSettle();
  }

  testWidgets('le remede se propose, et se lance', (tester) async {
    var fait = 0;
    await ouvrir(tester, remede: Remede('Encaisser', () => fait++));
    expect(find.text('OK'), findsNothing);
    await tester.tap(find.text('Encaisser'));
    await tester.pumpAndSettle();
    expect(fait, 1);
    expect(find.text('Il reste 5 000 FCFA à payer.'), findsNothing);
  });

  testWidgets('plus tard ferme sans rien lancer', (tester) async {
    var fait = 0;
    await ouvrir(tester, remede: Remede('Encaisser', () => fait++));
    await tester.tap(find.text('Plus tard'));
    await tester.pumpAndSettle();
    expect(fait, 0);
    expect(find.text('Il reste 5 000 FCFA à payer.'), findsNothing);
  });

  testWidgets('sans remede, le refus garde son OK', (tester) async {
    await ouvrir(tester);
    expect(find.text('OK'), findsOneWidget);
    expect(find.text('Plus tard'), findsNothing);
  });
}
