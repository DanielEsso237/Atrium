/// La sortie de stock sans vente : utilisation ou perte, motif obligatoire.
///
/// La fenetre de saisie a porte aussi l'entree et le transfert, partis
/// depuis vers leur ecran plein (`ouvrirMouvementStock`). Ce test garde ce
/// qui lui reste : la sortie.
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
  testWidgets(
    'l econome sort 3 bouteilles cassees : une perte, motif compris',
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
                id: economat,
                createdAt: now,
                updatedAt: now,
                hotelId: _hotel,
                code: 'ECONOMAT',
                label: 'Économat',
                isCentral: const Value(true),
              ),
            );
        vin = newId();
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: vin,
                createdAt: now,
                updatedAt: now,
                hotelId: _hotel,
                reference: 'VIN',
                label: 'Vin rouge',
                purchasePrice: const Value(4500),
              ),
            );
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
        econome = await (db.select(
          db.users,
        )..where((u) => u.id.equals(id))).getSingle();
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
                    permissions: {'stock.read', 'stock.manage'},
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
      await tester.tap(find.text('Sortie'));
      await attendre();
      expect(find.text('Sortie de Économat'), findsOneWidget);
      // Une sortie n'a ni prix d'achat ni destination.
      expect(find.text('Prix d’achat unitaire'), findsNothing);
      expect(find.text('Vers'), findsNothing);

      await tester.tap(find.widgetWithText(InputDecorator, 'Produit'));
      await attendre();
      await tester.tap(find.text('Vin rouge (U)').last);
      await attendre();
      await tester.tap(find.text('Perte / casse'));
      await tester.enterText(
        find.widgetWithText(InputDecorator, 'Quantité'),
        '3',
      );
      await tester.pump();
      final enregistrer = find.widgetWithText(
        FilledButton,
        'Enregistrer la sortie',
      );
      // Sans motif, rien ne part.
      expect(tester.widget<FilledButton>(enregistrer).onPressed, isNull);
      await tester.enterText(
        find.widgetWithText(InputDecorator, 'Motif'),
        'Casse au service',
      );
      await tester.pump();
      await tester.tap(enregistrer);
      await attendre();

      final mouvements = await tester.runAsync(
        () => db.select(db.stockMovements).get(),
      );
      expect(mouvements, hasLength(1));
      final m = mouvements!.single;
      expect(m.type, StockMovementType.LOSS);
      expect(m.quantity, 3);
      expect(m.productId, vin);
      expect(m.stockLocationId, economat);
      expect(m.reason, 'Casse au service');

      // La base est en memoire : pas de close, qui attendrait une lecture en
      // suspens dans le temps simule.
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
  );
}
