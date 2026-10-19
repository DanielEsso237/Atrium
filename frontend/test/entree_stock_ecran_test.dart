/// L'entree de stock en plein ecran (15 octobre) : plusieurs produits d'un
/// coup, la quantite tapee au clavier -- cent bouteilles, c'est « 100 ».
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/stock/stock_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
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

void main() {
  testWidgets('l econome entre 100 bouteilles de vin et 13 bieres d un coup',
      (tester) async {
    final db = AtriumDatabase.memory();
    late UserRow econome;
    late String economat;
    late String vin;
    await tester.runAsync(() async {
      final now = DateTime.now().toUtc();
      economat = newId();
      await db
          .into(db.stockLocations)
          .insert(
            StockLocationsCompanion.insert(
              id: economat, createdAt: now, updatedAt: now, hotelId: _hotel,
              code: 'ECONOMAT', label: 'Économat', isCentral: const Value(true),
            ),
          );
      vin = newId();
      for (final (id, ref, label, prix) in [
        (vin, 'VIN', 'Vin rouge', 4500),
        (newId(), 'BIE', 'Biere 65 cl', 600),
      ]) {
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
                reference: ref, label: label,
                purchasePrice: Value(prix),
              ),
            );
      }
      final id = newId();
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
              employeeCode: 'ECO01', firstName: 'Paul', lastName: 'Essomba',
            ),
          );
      econome = await (db.select(db.users)..where((u) => u.id.equals(id)))
          .getSingle();
    });
    AtriumPalette.current = AtriumPalette.light;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
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
                  },
                ),
              ),
            ),
          ),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const StockScreen()),
      ),
    );
    Future<void> attendre() async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump();
      }
    }

    await attendre();
    expect(tester.takeException(), isNull, reason: 'écran Stocks');
    await tester.tap(find.text('Entrée'));
    await attendre();
    expect(tester.takeException(), isNull);
    expect(find.text('Entrée à Économat'), findsOneWidget);

    // Le vin : toucher, puis taper la quantite, deja selectionnee.
    // L'ecran Stocks reste dessous : on vise la fiche, ouverte par-dessus.
    await tester.tap(find.text('Vin rouge').last);
    await attendre();
    await tester.enterText(
        find.widgetWithText(InputDecorator, 'Quantité'), '100');
    // La biere : un carton de 12 en plus de la premiere, d'un geste.
    await tester.tap(find.text('Biere 65 cl').last);
    await attendre();
    await tester.tap(find.text('+12').last);
    await tester.pump();
    expect(find.textContaining('2 produits, 113 unités'), findsOneWidget);

    await tester.tap(find.text('Enregistrer l’entrée'));
    await attendre();
    // De retour sur l'ecran Stocks, rempli : la police de test, plus large
    // que la vraie, y fait deborder une case de quelques pixels. Seul ce
    // debordement est tolere ici ; toute autre erreur fait echouer.
    final erreur = tester.takeException();
    expect(erreur == null || '$erreur'.contains('overflowed'), isTrue,
        reason: '$erreur');

    final entrees = await tester.runAsync(
      () => (db.select(
        db.stockMovements,
      )..where((m) => m.type.equalsValue(StockMovementType.IN))).get(),
    );
    expect(entrees, hasLength(2));
    final duVin = entrees!.firstWhere((m) => m.productId == vin);
    expect(duVin.quantity, 100);
    expect(duVin.stockLocationId, economat);
    expect(entrees.map((m) => m.quantity).toSet(), {100, 13});

    // Pas de db.close : une lecture lancee par l'ecran reste en suspens dans
    // le temps simule, et la fermeture l'attendrait sans fin. La base est en
    // memoire, elle disparait avec le test.
    await tester.pumpWidget(const SizedBox());
    // Les flux de la base se ferment par minuteries : on les laisse partir.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
