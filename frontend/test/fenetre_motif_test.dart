/// La fenetre du motif se ferme par le retour d'Android sans casser l'arbre.
///
/// Le 16 octobre, sur l'ecran Reservations : « Annuler la reservation »,
/// puis retour sans rien annuler, et l'application levait
/// `_dependents.isEmpty`. Le controleur du motif etait detruit pendant
/// l'animation de sortie de la fenetre, alors que son champ l'utilisait
/// encore.
library;

import 'package:atrium/core/ui/fenetre_motif.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<BuildContext> monter(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold(body: Text('Réservations'));
          },
        ),
      ),
    );
    return ctx;
  }

  testWidgets('le retour d Android ferme la fenetre sans erreur', (
    tester,
  ) async {
    final ctx = await monter(tester);
    String? rendu = 'pas encore';
    demanderMotif(
      ctx,
      titre: 'Annuler la réservation',
      libelleRenoncer: 'Garder la réservation',
      libelleConfirmer: 'Annuler la réservation',
    ).then((m) => rendu = m);
    await tester.pumpAndSettle();
    // Le champ a le focus, comme quand l'agent a touche le motif.
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'client absent');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(rendu, isNull);
    expect(find.text('Garder la réservation'), findsNothing);
  });

  testWidgets('confirmer rend le motif, renoncer rend null', (tester) async {
    final ctx = await monter(tester);
    String? rendu;
    demanderMotif(
      ctx,
      titre: 'Annuler la réservation',
      libelleRenoncer: 'Garder la réservation',
      libelleConfirmer: 'Annuler la réservation',
    ).then((m) => rendu = m);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'client absent');
    await tester.tap(
      find.widgetWithText(FilledButton, 'Annuler la réservation'),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(rendu, 'client absent');

    rendu = 'pas encore';
    demanderMotif(
      ctx,
      titre: 'Annuler la réservation',
      libelleRenoncer: 'Garder la réservation',
      libelleConfirmer: 'Annuler la réservation',
    ).then((m) => rendu = m);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Garder la réservation'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(rendu, isNull);
  });
}
