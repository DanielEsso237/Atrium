/// La fenetre du code responsable s'affiche, sur tablette comme sur
/// telephone, et rend l'accord saisi.
///
/// Le 16 octobre, elle ne s'affichait pas du tout : un AlertDialog mesure la
/// largeur naturelle de son contenu, et les cases du PIN reposent sur un
/// LayoutBuilder (« LayoutBuilder does not support returning intrinsic
/// dimensions »). Aucun test n'ouvrait la fenetre.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/repositories/autorisation_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/annulations/accord_responsable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Autorisation implements AutorisationRepository {
  @override
  Future<Responsable> verifier({
    required String code,
    required String secret,
    String permission = droitAnnuler,
  }) async {
    if (code != 'ADMIN01' || secret != '1234') {
      throw StateError('Code ou PIN incorrect.');
    }
    return const Responsable(id: 'admin', nom: 'Admin Démo');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final taille in [const Size(1200, 1920), const Size(400, 800)]) {
    testWidgets('la fenetre s affiche et rend l accord (${taille.width} px)', (
      tester,
    ) async {
      AtriumPalette.current = AtriumPalette.light;
      tester.view.physicalSize = taille;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late BuildContext ctx;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            autorisationRepositoryProvider.overrideWithValue(_Autorisation()),
          ],
          child: MaterialApp(
            theme: themeAtrium(),
            home: Builder(
              builder: (c) {
                ctx = c;
                return const Scaffold(body: Text('Réservations'));
              },
            ),
          ),
        ),
      );

      Accord? accord;
      var rendu = false;
      demanderAccordResponsable(
        ctx,
        titre: "Annuler l'arrivée",
        explication: 'Mme Diallo quitte la chambre 101.',
      ).then((a) {
        accord = a;
        rendu = true;
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text("Annuler l'arrivée"), findsOneWidget);
      expect(find.text('Autoriser'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'ADMIN01');
      for (final c in ['1', '2', '3', '4']) {
        await tester.tap(find.text(c).last);
        await tester.pump();
      }
      await tester.enterText(find.byType(TextField).last, 'Mauvaise chambre');
      await tester.pump();
      await tester.ensureVisible(find.text('Autoriser'));
      await tester.tap(find.text('Autoriser'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(rendu, isTrue);
      expect(accord?.responsable.nom, 'Admin Démo');
      expect(accord?.motif, 'Mauvaise chambre');
    });
  }
}
