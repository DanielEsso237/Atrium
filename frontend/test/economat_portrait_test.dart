/// L'ecran de l'economat tient sur la tablette, en portrait comme en paysage.
///
/// Vu sur la Samsung le 25 octobre : en portrait (800 points de large),
/// l'ecran debordait de partout.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/stock_repository.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/stock/stock_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull, Column, Table;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

class _Session extends SessionNotifier {
  _Session(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

/// Un economat, un bar, quelques produits en stock et deux demandes de
/// transfert en attente. Rend l'econome.
Future<UserRow> _hotelDEssai(AtriumDatabase db) async {
  final now = DateTime.now().toUtc();
  final economat = newId();
  final bar = newId();
  for (final (id, code, label, central) in [
    (economat, 'ECONOMAT', 'Économat', true),
    (bar, 'BAR', 'Bar de la piscine', false),
  ]) {
    await db
        .into(db.stockLocations)
        .insert(
          StockLocationsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            code: code,
            label: label,
            isCentral: Value(central),
          ),
        );
  }
  final stock = StockRepository(db);
  final produits = <String>[];
  for (final (ref, label, prix) in [
    ('VIN', 'Vin rouge Bordeaux supérieur 75 cl', 4500),
    ('BIE', 'Bière 65 cl', 600),
    ('SAV', 'Savon de toilette parfumé 100 g', 250),
  ]) {
    final id = newId();
    produits.add(id);
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            reference: ref,
            label: label,
            purchasePrice: Value(prix),
            minStock: const Value(20),
          ),
        );
    await stock.receive(
      placeId: economat,
      productId: id,
      quantity: 12,
      unitCost: prix,
    );
  }
  for (final p in produits.take(2)) {
    await stock.requestTransfer(
      fromPlaceId: economat,
      toPlaceId: bar,
      productId: p,
      quantity: 24,
    );
  }
  final id = newId();
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: id,
          createdAt: now,
          updatedAt: now,
          hotelId: _hotel,
          employeeCode: 'ECO01',
          firstName: 'Paul',
          lastName: 'Essomba',
        ),
      );
  return (db.select(db.users)..where((u) => u.id.equals(id))).getSingle();
}

void main() {
  // Un seul test pour les trois tailles : le son des alertes n'a pas de
  // greffon en test, et son erreur, levee apres coup, retombait sur le
  // test suivant.
  testWidgets('l economat s affiche sans debordement, et Ajuster se ferme', (
    tester,
  ) async {
    AtriumPalette.current = AtriumPalette.light;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final erreurs = <String>[];
    final constats = <String, List<Object>>{};
    final avant = FlutterError.onError;
    // Tout sauf le son des alertes, qui n'a pas de greffon en test.
    FlutterError.onError = (d) {
      final e = d.exceptionAsString();
      if (!e.contains('MissingPluginException')) erreurs.add(e);
    };

    Future<void> laisserVivre() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
    }

    for (final taille in const [
      Size(1280, 800),
      Size(700, 1280),
      Size(800, 1280),
    ]) {
      final ou = '${taille.width.toInt()} x ${taille.height.toInt()}';
      tester.view.physicalSize = taille;
      // Pas de db.close : une lecture lancee par l'ecran reste en suspens
      // dans le temps simule, et la fermeture l'attendrait sans fin. La base
      // est en memoire, elle disparait avec le test.
      final db = AtriumDatabase.memory();
      final econome = (await tester.runAsync(() => _hotelDEssai(db)))!;
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(ou),
          overrides: [
            databaseProvider.overrideWithValue(db),
            pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
            sessionProvider.overrideWith(
              () => _Session(
                SessionState(
                  agent: econome,
                  acces: const AccessProfile(
                    permissions: {
                      'stock.read',
                      'stock.manage',
                      'stock.transfer.request',
                      'stock.transfer.approve',
                      'stock.inventory',
                      'accounting.read',
                    },
                  ),
                ),
              ),
            ),
          ],
          child: MaterialApp(theme: themeAtrium(), home: const StockScreen()),
        ),
      );
      await laisserVivre();
      await laisserVivre();

      final titre = find.text('Transferts à valider').evaluate().length;
      final colonne = find
          .descendant(of: find.byType(Table), matching: find.text('En stock'))
          .evaluate()
          .length;
      final court = find.text('pas assez').evaluate().length;

      // Ajuster : la fenetre se ferme en animant, son champ encore a
      // l'ecran. Vu le 25 octobre : controleur detruit, application en
      // erreur.
      final ajuster = find.widgetWithText(OutlinedButton, 'Ajuster').first;
      await tester.ensureVisible(ajuster);
      await laisserVivre();
      await tester.tap(ajuster);
      await laisserVivre();
      final fenetre = find.byType(AlertDialog).evaluate().length;
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '10',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Ajuster'));
      await laisserVivre();
      final fermee = find.byType(AlertDialog).evaluate().isEmpty;

      constats[ou] = [
        titre,
        colonne,
        court,
        fenetre,
        fermee,
        [...erreurs],
      ];
      erreurs.clear();
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await tester.pump(const Duration(seconds: 5));
    FlutterError.onError = avant;

    for (final MapEntry(key: ou, value: c) in constats.entries) {
      expect(c, [1, 1, 2, 1, true, <String>[]], reason: ou);
    }
  });
}
