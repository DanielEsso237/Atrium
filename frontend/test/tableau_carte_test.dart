/// La carte en tableau des fiches en plein ecran (15 octobre) : ce qui se
/// vend le plus d'abord, la recherche, un article en rupture qu'on ne
/// choisit pas. Sans base de donnees : le tableau ne lit que ce qu'on lui
/// donne.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/features/orders/tableau_carte.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _carte = [
  MenuEntry(
    id: 'castel',
    label: 'Castel',
    price: 1200,
    isAvailable: true,
    categoryLabel: 'Bières',
    vendus: 42,
    enStock: 10,
  ),
  MenuEntry(
    id: 'jus',
    label: 'Jus d’orange',
    price: 1000,
    isAvailable: true,
    categoryLabel: 'Jus',
    vendus: 7,
    enStock: 0,
  ),
  MenuEntry(
    id: 'whisky',
    label: 'Whisky',
    price: 5000,
    isAvailable: false,
    categoryLabel: 'Alcools',
    vendus: 1,
  ),
];

void main() {
  testWidgets('le nom et le stock, la recherche, la rupture', (tester) async {
    AtriumPalette.current = AtriumPalette.light;
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final choisis = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: themeAtrium(),
        home: Scaffold(
          body: TableauCarte(
            carte: _carte,
            dejaChoisis: (e) => e.id == 'castel' ? 2 : 0,
            onChoisi: (e) => choisis.add(e.id),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // Ni les ventes ni le prix (16 octobre) : la commande a la place.
    expect(find.text('42'), findsNothing);
    expect(find.text('Vendus'), findsNothing);
    expect(find.text('Prix'), findsNothing);
    expect(find.text('En stock'), findsOneWidget);
    // En stock : 10 Castel, plus de jus, le whisky ne sort d'aucun stock.
    expect(find.text('10'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    // Deja deux fois dans la commande.
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Alcools · rupture'), findsOneWidget);

    await tester.tap(find.text('Castel'));
    await tester.tap(find.text('Whisky'));
    expect(choisis, ['castel']);

    await tester.enterText(find.byType(TextField), 'jus');
    await tester.pump();
    expect(find.text('Castel'), findsNothing);
    expect(find.text('Jus d’orange'), findsOneWidget);
  });
}
