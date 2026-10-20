/// Les commandes en chambre sur l'ecran du point de vente (F2.7, reunion du
/// 18 octobre).
///
/// La reception a commande deux bieres pour la 101 : le bar voit la commande
/// en tete de son ecran, et la livre. Devant le plateau, le client paie
/// maintenant ou laisse sur l'ardoise de sa chambre.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/data/repositories/room_order_repository.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/orders/orders_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

const _hotel = FolioRepository.defaultHotelId;
const _categorie = '01920000-0000-7000-8000-0000000d0101';
const _biere = '01920000-0000-7000-8000-0000000d0001';

void main() {
  late AtriumDatabase db;
  late UserRow agent;
  late String commande;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    agent = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    final bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    final now = DateTime.now().toUtc();
    await db
        .into(db.menuCategories)
        .insert(
          MenuCategoriesCompanion.insert(
            id: _categorie,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            label: 'Boissons',
            outletId: Value(bar.id),
          ),
        );
    await db
        .into(db.menuItems)
        .insert(
          MenuItemsCompanion.insert(
            id: _biere,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            code: 'BIE',
            label: 'Bière',
            menuCategoryId: _categorie,
            price: const Value(1500),
          ),
        );
    await CashRepository(
      db,
    ).open(userId: agent.id, openingFloat: 0, outletId: bar.id);

    final client = (await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo')).id;
    final chambre = await (db.select(
      db.rooms,
    )..where((r) => r.number.equals('101'))).getSingle();
    final reservations = ReservationRepository(db);
    final dossier = await reservations.create(
      guestId: client,
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
    final ardoise = await (db.select(
      db.folios,
    )..where((f) => f.reservationRoomId.equals(ligne.id))).getSingle();
    commande = await RoomOrderRepository(db).commander(
      outletId: bar.id,
      folioId: ardoise.id,
      lignes: [(menuItemId: _biere, quantite: 2, notes: null)],
      by: agent.id,
    );
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  Future<void> attendre(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> monter(WidgetTester tester, double largeur) async {
    tester.view.physicalSize = Size(largeur, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final acces = (await tester.runAsync(
      () => accessProfileFor(db, agent.id),
    ))!;
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
    await attendre(tester);
  }

  for (final largeur in [1280.0, 400.0]) {
    testWidgets('la commande s affiche en tete, sans deborder ($largeur px)', (
      tester,
    ) async {
      await monter(tester, largeur);

      expect(tester.takeException(), isNull);
      expect(find.text('1 commande en chambre à monter'), findsOneWidget);
      expect(find.text('Chambre 101'), findsOneWidget);
      expect(find.text('2 × Bière'), findsOneWidget);
      expect(find.text('Prendre en charge'), findsOneWidget);
      expect(find.text('Livrer'), findsOneWidget);

      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('le client paie a la livraison', (tester) async {
    await monter(tester, 1280);

    await tester.tap(find.text('Livrer'));
    await attendre(tester);
    await tester.tap(find.text('Le client paie maintenant'));
    await attendre(tester);
    await tester.tap(find.text('Encaisser et livrer'));
    await attendre(tester);

    expect(tester.takeException(), isNull);
    final c = (await tester.runAsync(
      () => (db.select(
        db.orders,
      )..where((o) => o.id.equals(commande))).getSingle(),
    ))!;
    expect(c.status, OrderStatus.SERVED);
    final paiements = (await tester.runAsync(
      () => db.select(db.payments).get(),
    ))!;
    expect(paiements.single.amount, 3000);
    expect(paiements.single.method, PaymentMethod.CASH);
    // Livree : le bandeau s'efface.
    expect(find.text('1 commande en chambre à monter'), findsNothing);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });
}
