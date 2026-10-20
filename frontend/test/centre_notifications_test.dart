/// Le centre de notifications (19 octobre).
///
/// Ce qui compte : une commande en chambre sonne au point de vente qui la
/// recoit, pas a la reception qui l'a passee, et se tait des qu'elle est
/// prise en charge ; l'historique garde chaque notification avec son issue,
/// selon les droits de l'agent ; et la carte de la commande se prend en
/// charge puis se livre depuis le panneau de la cloche.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/widgets/module_scaffold.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/alert_queries.dart';
import 'package:atrium/data/local/queries/historique_notifications_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/data/repositories/room_order_repository.dart';
import 'package:atrium/features/alerts/alert_signal.dart';
import 'package:atrium/features/alerts/centre_notifications.dart';
import 'package:atrium/features/alerts/system_notifications.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _hotel = FolioRepository.defaultHotelId;
const _biere = '01920000-0000-7000-8000-0000000c0001';

/// Le haut-parleur de la tablette : on note ce qui sonne.
class _SignalNote implements SignalAlerte {
  final emis = <NiveauAlerte>[];

  @override
  Future<void> emettre(
    NiveauAlerte niveau, {
    required Sonnerie sonnerie,
    bool son = true,
    bool vibration = true,
  }) async => emis.add(niveau);

  @override
  Future<void> arreter() async {}
}

class _VoletMuet implements NotificationsSysteme {
  @override
  Future<void> preparer(void Function(String, String?) surTouche) async {}

  @override
  Future<void> veiller(bool actif) async {}

  @override
  Future<void> montrer(Alerte alerte, SignalVoulu signal) async {}

  @override
  Future<void> retirer(String cle) async {}

  @override
  Future<void> effacer() async {}
}

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late OutletRow bar;
  late RoomOrderRepository commandes;
  late String ardoise;
  late String receptionniste;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    final now = DateTime.now().toUtc();
    await db.into(db.menuCategories).insert(
      MenuCategoriesCompanion.insert(
        id: '01920000-0000-7000-8000-0000000c0101',
        createdAt: now,
        updatedAt: now,
        hotelId: _hotel,
        label: 'Bières',
        outletId: Value(bar.id),
      ),
    );
    await db.into(db.menuItems).insert(
      MenuItemsCompanion.insert(
        id: _biere,
        createdAt: now,
        updatedAt: now,
        hotelId: _hotel,
        code: 'BIE',
        label: 'Bière',
        menuCategoryId: '01920000-0000-7000-8000-0000000c0101',
        price: const Value(1500),
        taxRate: const Value(18),
      ),
    );
    commandes = RoomOrderRepository(db);
    // L'administrateur de demonstration tient le bar ; la reception commande.
    await db.into(db.userOutlets).insert(
      UserOutletsCompanion.insert(userId: utilisateurDemo, outletId: bar.id),
    );
    receptionniste = (await (db.select(db.users)
              ..where((u) => u.employeeCode.equals('RECEP01')))
            .getSingle())
        .id;

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
    ardoise = (await (db.select(
      db.folios,
    )..where((f) => f.reservationRoomId.equals(ligne.id))).getSingle()).id;
    // Le bar est ouvert : on ne lui commande rien sinon.
    await CashRepository(
      db,
    ).open(userId: utilisateurDemo, openingFloat: 0, outletId: bar.id);
  });

  Future<String> deuxBieres() => commandes.commander(
    outletId: bar.id,
    folioId: ardoise,
    lignes: [(menuItemId: _biere, quantite: 2, notes: 'bien fraîches')],
    by: receptionniste,
  );

  ContexteAlertes pour(String agent, Set<String> droits) => ContexteAlertes(
    agentId: agent,
    peut: droits.contains,
    maintenant: DateTime.now(),
  );

  group('donnees', () {
    tearDown(() => db.close());

    test('la commande sonne au bar qui la recoit, pas a la reception, et se '
        'tait une fois prise en charge', () async {
      final id = await deuxBieres();

      final auBar = await db.chargerAlertes(
        pour(utilisateurDemo, {'order.manage', 'order.read'}),
      );
      final alerte = auBar.singleWhere(
        (a) => a.type == TypeEvenement.commandeChambre,
      );
      expect(alerte.cle, 'commande-$id');
      expect(alerte.titre, 'Commande en chambre : chambre 101');
      expect(alerte.corps, contains('2 × Bière'));
      expect(alerte.corps, contains('pour Bar'));
      expect(alerte.route, routeCentreNotifications);

      // La reception l'a passee : elle la suit, elle n'en sonne pas.
      final aLaReception = await db.chargerAlertes(
        pour(receptionniste, {'order.manage', 'room_order.create'}),
      );
      expect(
        aLaReception.where((a) => a.type == TypeEvenement.commandeChambre),
        isEmpty,
      );

      await commandes.prendreEnCharge(orderId: id, by: utilisateurDemo);
      final apres = await db.chargerAlertes(
        pour(utilisateurDemo, {'order.manage', 'order.read'}),
      );
      expect(
        apres.where((a) => a.type == TypeEvenement.commandeChambre),
        isEmpty,
      );
    });

    test('le centre suit les commandes en route : celles de ses points de '
        'vente pour le bar, toutes pour la reception', () async {
      await deuxBieres();
      final autre = await OutletRepository(
        db,
      ).create(code: 'PISC', label: 'Piscine');
      await db.into(db.userOutlets).insert(
        UserOutletsCompanion.insert(userId: receptionniste, outletId: autre.id),
      );
      // Rattachee a la piscine seulement, elle ne voit plus le bar.
      expect(await commandes.watchEnRoutePourAgent(receptionniste).first, isEmpty);
      final auBar = await commandes.watchEnRoutePourAgent(utilisateurDemo).first;
      expect(auBar.single.lignes.single.quantite, 2);
      expect(auBar.single.commandeePar, isNotNull);
    });

    test('l historique garde la commande livree avec qui l a montee, et suit '
        'les droits de l agent', () async {
      final id = await deuxBieres();
      await commandes.prendreEnCharge(orderId: id, by: utilisateurDemo);
      await commandes.livrer(orderId: id, by: utilisateurDemo);

      final auBar = await db
          .watchHistoriqueNotifications(
            pour(utilisateurDemo, {'order.read', 'order.manage'}),
          )
          .first;
      final ligne = auBar.singleWhere((n) => n.cle == 'commande-$id');
      expect(ligne.issue, IssueNotification.reglee);
      expect(ligne.libelleIssue, startsWith('Livrée à '));
      expect(ligne.detail, '2 × Bière pour Bar');

      // Le menage ne lit pas les commandes du bar.
      final auMenage = await db
          .watchHistoriqueNotifications(
            pour(receptionniste, {'housekeeping.read'}),
          )
          .first;
      expect(auMenage.where((n) => n.type == TypeEvenement.commandeChambre), isEmpty);
    });

    test('l historique dit qu une commande annulee l a ete, et pourquoi', () async {
      final id = await deuxBieres();
      await commandes.annuler(
        orderId: id,
        motif: 'Client endormi',
        by: receptionniste,
      );
      final lignes = await db
          .watchHistoriqueNotifications(
            pour(receptionniste, {'room_order.create'}),
          )
          .first;
      final ligne = lignes.singleWhere((n) => n.cle == 'commande-$id');
      expect(ligne.issue, IssueNotification.annulee);
      expect(ligne.libelleIssue, contains('Client endormi'));
    });
  });

  group('ecran', () {
    late _SignalNote signal;

    Future<void> monter(WidgetTester tester, Widget ecran, Size taille) async {
      tester.view.physicalSize = taille;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final admin = (await tester.runAsync(
        () => (db.select(
          db.users,
        )..where((u) => u.id.equals(utilisateurDemo))).getSingle(),
      ))!;
      final acces = (await tester.runAsync(
        () => accessProfileFor(db, utilisateurDemo),
      ))!;
      signal = _SignalNote();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            signalAlerteProvider.overrideWithValue(signal),
            notificationsSystemeProvider.overrideWithValue(_VoletMuet()),
            sessionProvider.overrideWith(
              () => _TestSession(SessionState(agent: admin, acces: acces)),
            ),
            pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
          ],
          child: MaterialApp(theme: themeAtrium(), home: ecran),
        ),
      );
      await laisser(tester);
    }

    Future<void> fermer(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(db.close);
    }

    testWidgets('la cloche de chaque ecran ouvre le panneau, ou la commande se '
        'prend en charge puis se livre', (tester) async {
      final id = (await tester.runAsync(deuxBieres))!;
      await monter(
        tester,
        const ModuleScaffold(title: 'Stocks', body: SizedBox()),
        const Size(1280, 900),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(ClocheNotifications), findsOneWidget);
      // Le bar l'entend arriver.
      expect(signal.emis, contains(NiveauAlerte.urgente));
      expect(find.bySemanticsLabel('Notifications, 1 non vue'), findsOneWidget);

      await tester.tap(find.byType(ClocheNotifications));
      await laisser(tester);
      expect(find.text('Commandes en chambre'), findsOneWidget);
      expect(find.text('À prendre en charge'), findsOneWidget);
      expect(find.text('2 ×'), findsOneWidget);

      await tester.tap(find.text('Prendre en charge'));
      await laisser(tester);
      expect(find.text('En préparation'), findsOneWidget);
      final prise = (await tester.runAsync(
        () => (db.select(db.orders)..where((o) => o.id.equals(id))).getSingle(),
      ))!;
      expect(prise.status, OrderStatus.IN_PREP);

      await tester.tap(find.text('Livrer'));
      await laisser(tester);
      expect(find.text('Commandes en chambre'), findsNothing);

      await tester.tap(find.text('Historique'));
      await laisser(tester);
      expect(find.textContaining('Livrée à '), findsOneWidget);
      expect(tester.takeException(), isNull);
      await fermer(tester);
    });

    for (final taille in [const Size(1280, 900), const Size(390, 844)]) {
      testWidgets('l ecran des notifications tient sans debordement : $taille',
          (tester) async {
        await tester.runAsync(deuxBieres);
        await monter(tester, const CentreNotificationsScreen(), taille);
        expect(tester.takeException(), isNull);
        expect(find.text('Commandes en chambre'), findsOneWidget);
        await tester.tap(find.text('Historique'));
        await laisser(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Commande en chambre : chambre 101'), findsOneWidget);
        await fermer(tester);
      });
    }
  });
}

/// Laisse les lectures de la base aboutir et l'ecran se redessiner.
Future<void> laisser(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
}
