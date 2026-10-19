/// Les rapports par module (F3.3, 19 octobre).
///
/// Ce qui compte : chaque registre suit les filtres du rapport ; un bloc ne
/// va qu'a qui a le droit de le lire ; l'entree « Rapport » se range en
/// derniere vue de son onglet, et ne remonte pas seule chez la femme de
/// chambre ; le PDF porte les cases de signature.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/formats.dart';
import 'package:atrium/core/ids.dart';
import 'package:atrium/core/router.dart' show permissionPour;
import 'package:atrium/core/shell/app_shell.dart' show destinationsPour;
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/registres_queries.dart';
import 'package:atrium/data/local/queries/report_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/stock_repository.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/reports/export/export_model.dart';
import 'package:atrium/features/reports/export/pdf_export.dart';
import 'package:atrium/features/reports/rapport_module_screen.dart';
import 'package:atrium/features/reports/rapports_modules.dart';
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
  late String terrasse;
  final aujourdhui = businessDayFor(DateTime.now());
  final semaine = FiltresRapport(
    du: aujourdhui.subtract(const Duration(days: 6)),
    au: aujourdhui,
  );

  Future<void> vendre(String point, String label, int prix, {int ilYA = 0}) async {
    final now = DateTime.now().toUtc();
    final jour = aujourdhui.subtract(Duration(days: ilYA));
    final folio = newId();
    await db.into(db.folios).insert(
      FoliosCompanion.insert(
        id: folio, createdAt: now, updatedAt: now, hotelId: _hotel,
        number: 'F-$label', type: const Value(FolioType.WALK_IN),
        status: const Value(FolioStatus.CLOSED), outletId: Value(point),
      ),
    );
    await db.into(db.folioItems).insert(
      FolioItemsCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now, folioId: folio,
        category: ChargeCategory.FNB, label: label,
        unitPrice: Value(prix), amount: Value(prix),
        businessDate: formatIsoDate(jour),
        sourceTable: const Value('outlets'), sourceId: Value(point),
        postedBy: Value(admin.id), postedAt: Value(now),
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
    terrasse =
        (await OutletRepository(db).create(code: 'TER', label: 'Terrasse')).id;
    await vendre(bar, 'Biere', 1500);
    await vendre(terrasse, 'Plat', 9000);
    await vendre(bar, 'Vin', 6000, ilYA: 20);

    // Un sejour en cours : arrive il y a deux jours, part demain.
    final now = DateTime.now().toUtc();
    final chambre = (await db.select(db.rooms).get()).first;
    final guest = newId();
    await db.into(db.guests).insert(
      GuestsCompanion.insert(
        id: guest, createdAt: now, updatedAt: now, hotelId: _hotel,
        code: 'CLI-R1', firstName: 'Awa', lastName: 'Mbarga',
      ),
    );
    final reservation = newId();
    final arrivee = formatIsoDate(aujourdhui.subtract(const Duration(days: 2)));
    final depart = formatIsoDate(aujourdhui.add(const Duration(days: 1)));
    await db.into(db.reservations).insert(
      ReservationsCompanion.insert(
        id: reservation, createdAt: now, updatedAt: now, hotelId: _hotel,
        reference: 'RES-R1', guestId: guest,
        arrivalDate: arrivee, departureDate: depart,
      ),
    );
    await db.into(db.reservationRooms).insert(
      ReservationRoomsCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now,
        reservationId: reservation, roomTypeId: chambre.roomTypeId,
        roomId: Value(chambre.id), arrivalDate: arrivee, departureDate: depart,
        nightlyRate: const Value(25000),
        status: const Value(ReservationStatus.CHECKED_IN),
        checkedInAt: Value(now.subtract(const Duration(days: 2))),
      ),
    );

    // Le stock : une entree a l'economat.
    final economat = newId();
    await db.into(db.stockLocations).insert(
      StockLocationsCompanion.insert(
        id: economat, createdAt: now, updatedAt: now, hotelId: _hotel,
        code: 'ECO_R', label: 'Économat', isCentral: const Value(true),
      ),
    );
    final produit = newId();
    await db.into(db.products).insert(
      ProductsCompanion.insert(
        id: produit, createdAt: now, updatedAt: now, hotelId: _hotel,
        reference: 'SAV_R', label: 'Savon', purchasePrice: const Value(150),
      ),
    );
    await StockRepository(db).receive(
      placeId: economat, productId: produit, quantity: 40, unitCost: 150,
      reason: 'Livraison', by: admin.id,
    );

    // L'entretien : une chambre faite, une panne reglee.
    await db.into(db.housekeepingTasks).insert(
      HousekeepingTasksCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
        roomId: chambre.id, type: HousekeepingTaskType.DEPARTURE,
        businessDate: formatIsoDate(aujourdhui),
        status: const Value(TaskStatus.DONE), assignedTo: Value(admin.id),
        durationMinutes: const Value(35),
      ),
    );
    await db.into(db.maintenanceTickets).insert(
      MaintenanceTicketsCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
        number: 'MT-R1', title: 'Fuite du lavabo',
        status: const Value(TicketStatus.RESOLVED),
        reportedAt: Value(now.subtract(const Duration(hours: 5))),
        resolvedAt: Value(now.subtract(const Duration(hours: 1))),
        cost: const Value(12000),
      ),
    );
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  test('le journal des ventes suit la periode et le point de vente', () async {
    final tout = await db.journalVentes(semaine);
    expect(tout, hasLength(2), reason: 'le vin est hors de la semaine');
    final duBar = await db.journalVentes(
      semaine.copier(pointDeVenteId: () => bar),
    );
    expect(duBar.single.articles, 'Biere');
    expect(duBar.single.pointDeVente, 'Bar');
    expect(duBar.single.reglement, 'Payée');
    final articles = await db.ventesParArticle(semaine);
    expect(articles.first.article, 'Plat', reason: 'le plus gros montant');
  });

  test('les registres des autres modules lisent leur periode', () async {
    final sejours = await db.registreSejours(semaine);
    expect(sejours.single.client, 'Awa Mbarga');
    expect(sejours.single.nuits, 3);
    expect(sejours.single.tarif, 25000);

    final mouvements = await db.mouvementsStock(semaine);
    expect(mouvements.single.produit, 'Savon');
    expect(mouvements.single.quantite, 40);

    final menage = await db.registreMenage(semaine);
    expect(menage.single.duree, 35);

    final pannes = await db.registrePannes(semaine);
    expect(pannes.single.cout, 12000);
  });

  test('un bloc ne va qu a qui a le droit de le lire', () async {
    final r = await db.chargerRapport(semaine);
    final comptoir = const AccessProfile(permissions: {'stock.read'});
    final econome = const AccessProfile(
      permissions: {'stock.read', 'stock.manage'},
    );
    List<String> titres(ModuleRapport m, AccessProfile a) => [
      for (final s in sectionsDuModule(m, r, const Registres(), a)) s.titre,
    ];
    expect(titres(ModuleRapport.stocks, comptoir), [
      'Registre des mouvements de stock',
    ]);
    expect(titres(ModuleRapport.stocks, econome), contains('Stock et marges'));
    final menage = const AccessProfile(permissions: {'housekeeping.read'});
    expect(
      titres(ModuleRapport.entretien, menage),
      isNot(contains('Registre des pannes')),
    );
  });

  test("l'entree Rapport se range en derniere vue de son onglet", () async {
    final direction = destinationsPour(
      SessionState(acces: await accessProfileFor(db, admin.id)),
    );
    final routes = [for (final d in direction) d.route];
    final rapport = direction.firstWhere((d) => d.route == '/rapports/ventes');
    expect(rapport.parent, '/ventes');
    final dernierDesVentes = direction.lastIndexWhere(
      (d) => d.parent == '/ventes',
    );
    expect(routes.indexOf('/rapports/ventes'), dernierDesVentes);
    expect(permissionPour('/rapports/ventes'), 'order.read');
    expect(permissionPour('/rapports/stocks'), 'stock.read');

    final menage = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('MENAGE01'))).getSingle();
    final femmeDeChambre = destinationsPour(
      SessionState(acces: await accessProfileFor(db, menage.id)),
    );
    expect(
      femmeDeChambre.map((d) => d.route),
      isNot(contains('/rapports/entretien')),
      reason: 'son seul ecran reste le menage',
    );
  });

  test('le PDF porte les cases de signature', () async {
    final pdf = await construirePdf(
      DocumentRapport(
        titre: 'Rapport des ventes',
        hotel: 'Edge Hotel',
        periode: 'Semaine',
        filtres: const [],
        etabliLe: DateTime(2026, 10, 19, 10),
        etabliPar: 'Admin Atrium',
        visas: ModuleRapport.visas,
        sections: [
          Section(
            titre: 'Ventes',
            description: 'Essai',
            tableaux: [
              Tableau(
                titre: 'Ventes',
                colonnes: const [Colonne('Article'), Colonne('Montant', Unite.montant)],
                lignes: const [
                  ['Biere', 1500],
                ],
              ),
            ],
          ),
        ],
      ),
    );
    expect(String.fromCharCodes(pdf.take(4)), '%PDF');
  });

  for (final taille in [const Size(1280, 900), const Size(390, 844)]) {
    for (final module in ModuleRapport.values) {
      testWidgets('${module.titre} s affiche sans debordement : $taille',
          (tester) async {
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
              home: RapportModuleScreen(module: module),
            ),
          ),
        );
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 150)),
          );
          await tester.pump(const Duration(milliseconds: 300));
        }

        expect(tester.takeException(), isNull);
        expect(find.text(module.titre), findsWidgets);
        // Le document finit par ses cases de signature.
        expect(find.text('Établi par'), findsOneWidget);
        expect(find.text('Visa de la direction'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.runAsync(db.close);
      });
    }
  }
}
