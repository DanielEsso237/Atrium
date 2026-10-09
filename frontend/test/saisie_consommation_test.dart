/// La fenetre de saisie d'une consommation s'ouvre, et s'affiche.
///
/// Vecu sur tablette : la fenetre s'ouvrait en carre vide. Une erreur de mise
/// en page ne se voit pas dans un test de depot : il faut ouvrir l'ecran.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/orders/orders_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late UserRow agent;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    agent = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    final bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    final now = DateTime.now().toUtc();
    final categorie = newId();
    await db
        .into(db.menuCategories)
        .insert(
          MenuCategoriesCompanion.insert(
            id: categorie, createdAt: now, updatedAt: now, hotelId: _hotel,
            label: 'Bières', outletId: Value(bar.id),
          ),
        );
    await db
        .into(db.menuItems)
        .insert(
          MenuItemsCompanion.insert(
            id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
            code: 'MUTZIG', label: 'Mutzig', menuCategoryId: categorie,
            price: const Value(1000),
          ),
        );
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  testWidgets('la fenetre d un client loge s affiche, avec son historique',
      (tester) async {
    // Un client en chambre 101, avec son ardoise ouverte.
    await tester.runAsync(() async {
      final client = await GuestRepository(
        db,
      ).create(firstName: 'Awa', lastName: 'Diallo');
      final chambre = await (db.select(
        db.rooms,
      )..where((r) => r.number.equals('101'))).getSingle();
      final reservations = ReservationRepository(db);
      final dossier = await reservations.create(
        guestId: client.id,
        roomTypeId: chambre.roomTypeId,
        arrival: DateTime.now().subtract(const Duration(days: 1)),
        departure: DateTime.now().add(const Duration(days: 2)),
        nightlyRate: 25000,
        roomId: chambre.id,
      );
      final ligne = await (db.select(
        db.reservationRooms,
      )..where((l) => l.reservationId.equals(dossier))).getSingle();
      await reservations.checkIn(lineId: ligne.id);
    });

    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final acces = (await tester.runAsync(() => accessProfileFor(db, agent.id)))!;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(
            () => _TestSession(SessionState(agent: agent, acces: acces)),
          ),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const OrdersScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('101'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Consommation'), findsOneWidget);
    expect(find.text('Porter à la chambre'), findsOneWidget);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('la fenetre du client de passage s affiche', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final acces = (await tester.runAsync(() => accessProfileFor(db, agent.id)))!;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(
            () => _TestSession(SessionState(agent: agent, acces: acces)),
          ),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const OrdersScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Client de passage'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Consommation'), findsOneWidget);
    expect(find.text('Choisir le paiement'), findsOneWidget);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });
}
