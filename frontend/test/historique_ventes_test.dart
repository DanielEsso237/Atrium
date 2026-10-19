/// Le tableau de bord et l'historique des ventes (18 octobre).
///
/// Ce qui compte : une vente est une ardoise servie a un comptoir dans la
/// journee, avec ce qu'est devenu l'argent ; la recette jour par jour garde
/// les journees vides ; un tiroir se lit de son ouverture a son versement.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/formats.dart';
import 'package:atrium/core/ids.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/historique_pdv_queries.dart';
import 'package:atrium/data/local/queries/ventes_historique_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/outlets/historique_ventes_screen.dart';
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
  late UserRow admin;
  late String bar;
  final aujourdhui = businessDayFor(DateTime.now());

  /// Une ardoise du comptoir et sa ligne, servie il y a [ilYA] jours.
  Future<void> vendre({
    required String label,
    required int prix,
    int ilYA = 0,
    FolioStatus statut = FolioStatus.CLOSED,
    FolioType type = FolioType.WALK_IN,
  }) async {
    final now = DateTime.now().toUtc();
    final jour = aujourdhui.subtract(Duration(days: ilYA));
    final folio = newId();
    await db.into(db.folios).insert(
      FoliosCompanion.insert(
        id: folio, createdAt: now, updatedAt: now, hotelId: _hotel,
        number: 'FOL-$label', type: Value(type), status: Value(statut),
        outletId: Value(bar),
      ),
    );
    await db.into(db.folioItems).insert(
      FolioItemsCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now, folioId: folio,
        category: ChargeCategory.FNB, label: label, quantity: const Value(2),
        unitPrice: Value(prix), amount: Value(prix * 2),
        businessDate: formatIsoDate(jour),
        sourceTable: const Value('outlets'), sourceId: Value(bar),
        postedBy: Value(admin.id),
        postedAt: Value(
          DateTime(jour.year, jour.month, jour.day, 20).toUtc(),
        ),
      ),
    );
  }

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    admin = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    bar = (await OutletRepository(db).create(code: 'BAR', label: 'Bar')).id;
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  test('une vente dit a qui, quoi, par qui, et ou en est l argent', () async {
    await vendre(label: 'Biere', prix: 1500);
    await vendre(label: 'Jus', prix: 1000, statut: FolioStatus.OPEN);
    await vendre(label: 'Vin', prix: 6000, ilYA: 10);

    final semaine = await db
        .watchHistoriqueVentes(
          pointsDeVente: [bar],
          depuis: aujourdhui.subtract(const Duration(days: 6)),
        )
        .first;
    expect(semaine, hasLength(2), reason: 'le vin est hors de la semaine');
    final biere = semaine.firstWhere((v) => v.articles == '2 × Biere');
    expect(biere.montant, 3000);
    expect(biere.etat, EtatVentePdv.payee);
    expect(biere.agent, '${admin.firstName} ${admin.lastName}'.trim());
    expect(
      semaine.firstWhere((v) => v.articles == '2 × Jus').etat,
      EtatVentePdv.aPayer,
    );

    final tout = await db.watchHistoriqueVentes(pointsDeVente: [bar]).first;
    expect(tout, hasLength(3));
    // La plus recente d'abord : le vin, il y a dix jours, ferme la liste.
    expect(tout.last.articles, '2 × Vin');
  });

  test('la recette jour par jour garde les journees vides', () async {
    await vendre(label: 'Biere', prix: 1500);
    await vendre(label: 'Vin', prix: 6000, ilYA: 3);

    final jours = await db
        .watchRecetteParJour(
          pointsDeVente: [bar],
          du: aujourdhui.subtract(const Duration(days: 6)),
          au: aujourdhui,
        )
        .first;
    expect(jours, [0, 0, 0, 12000, 0, 0, 3000]);
  });

  test('un tiroir se lit de son ouverture a sa reception', () async {
    final now = DateTime.now().toUtc();
    await db.into(db.cashSessions).insert(
      CashSessionsCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
        userId: admin.id, outletId: Value(bar),
        status: const Value(CashSessionStatus.CLOSED),
        openedAt: Value(now.subtract(const Duration(hours: 8))),
        openingFloat: const Value(20000),
        closedAt: Value(now.subtract(const Duration(hours: 1))),
        countedAmount: const Value(45000),
        expectedAmount: const Value(46000),
      ),
    );
    final tiroirs = await db
        .watchHistoriqueTiroirs(pointsDeVente: [bar])
        .first;
    expect(tiroirs, hasLength(1));
    expect(tiroirs.single.fond, 20000);
    expect(tiroirs.single.declare, 45000);
    expect(tiroirs.single.recuLe, isNull, reason: 'pas encore recu');
    expect(tiroirs.single.agent, isNotNull);
  });

  for (final taille in [const Size(1280, 800), const Size(390, 844)]) {
    testWidgets('l historique des ventes s affiche sans debordement : $taille',
        (tester) async {
      await tester.runAsync(() async {
        await vendre(label: 'Biere', prix: 1500);
        await vendre(label: 'Jus', prix: 1000, statut: FolioStatus.OPEN);
      });
      tester.view.physicalSize = taille;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final acces =
          (await tester.runAsync(() => accessProfileFor(db, admin.id)))!;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            sessionProvider.overrideWith(
              () => _TestSession(SessionState(agent: admin, acces: acces)),
            ),
            pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
          ],
          child: MaterialApp(
            theme: themeAtrium(),
            home: const HistoriqueVentesScreen(),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Historique des ventes'), findsOneWidget);
      expect(find.text("Aujourd'hui"), findsWidgets);
      expect(find.textContaining('2 × Biere'), findsOneWidget);
      // Le filtre « À payer » ne garde que le jus.
      await tester.ensureVisible(find.text('À payer').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('À payer').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('2 × Biere'), findsNothing);
      expect(find.textContaining('2 × Jus'), findsOneWidget);

      await tester.runAsync(db.close);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
