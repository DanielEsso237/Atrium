/// Le barman demande le ravitaillement de son bar.
///
/// Vecu le 11 octobre : connecte en agent, Stocks > Transfert ne faisait
/// rien. L'agent ne voit que son bar ; le transfert partait de l'onglet vers
/// les autres magasins qu'il voyait -- aucun --, et s'arretait sans un mot.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
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
  testWidgets('sur l onglet du bar, Transfert ouvre un ravitaillement',
      (tester) async {
    final db = AtriumDatabase.memory();
    late UserRow barman;
    await tester.runAsync(() async {
      final now = DateTime.now().toUtc();
      final outlet = newId();
      await db
          .into(db.outlets)
          .insert(
            OutletsCompanion.insert(
              id: outlet, createdAt: now, updatedAt: now, hotelId: _hotel,
              code: 'BAR', label: 'Bar',
            ),
          );
      await db
          .into(db.stockLocations)
          .insert(
            StockLocationsCompanion.insert(
              id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
              code: 'ECONOMAT', label: 'Économat', isCentral: const Value(true),
            ),
          );
      await db
          .into(db.stockLocations)
          .insert(
            StockLocationsCompanion.insert(
              id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
              code: 'BAR', label: 'Bar', sortOrder: const Value(10),
              outletId: Value(outlet),
            ),
          );
      final id = newId();
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
              employeeCode: 'BAR01', firstName: 'Ines', lastName: 'Mbarga',
            ),
          );
      await db
          .into(db.userOutlets)
          .insert(UserOutletsCompanion.insert(userId: id, outletId: outlet));
      barman = await (db.select(db.users)..where((u) => u.id.equals(id)))
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
                agent: barman,
                acces: const AccessProfile(
                  permissions: {'stock.read', 'stock.transfer.request'},
                  genres: {'OUTLET'},
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
    // Le barman ne voit que son bar.
    expect(find.text('Stock du point de vente Bar'), findsOneWidget);

    await tester.tap(find.text('Transfert'));
    await attendre();

    expect(tester.takeException(), isNull);
    expect(find.text('Ravitailler Bar'), findsOneWidget);
    expect(find.text('Depuis'), findsOneWidget);
    expect(find.text('Demander le ravitaillement'), findsOneWidget);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });
}
