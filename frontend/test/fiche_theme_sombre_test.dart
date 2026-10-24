import 'package:atrium/core/tokens.dart';
import 'package:atrium/core/widgets/fiche_laterale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Essai du 24 octobre : en theme sombre, le titre, le montant et les boutons
// ronds de l'en-tete des fiches etaient ecrits dans la couleur du papier,
// foncee la nuit, sur une photo assombrie : presque invisibles.
void main() {
  tearDown(() => AtriumPalette.current = AtriumPalette.light);

  testWidgets('en theme sombre, l en-tete reste ecrit en clair', (
    tester,
  ) async {
    AtriumPalette.current = AtriumPalette.dark;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FicheEnTete(
            panneau: true,
            titre: 'Chambre 201',
            sousTitre: 'Double',
            valeur: '25 000 FCFA',
            actions: [
              FicheBoutonRond(
                icone: Icons.build_outlined,
                libelle: 'Signaler un problème',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final clair = AtriumPalette.dark.onNight;
    expect(tester.widget<Text>(find.text('Chambre 201')).style?.color, clair);
    expect(tester.widget<Text>(find.text('25 000 FCFA')).style?.color, clair);
    final icone = tester.widget<Icon>(find.byIcon(Icons.build_outlined));
    expect(icone.color, clair);
  });
}
