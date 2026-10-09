/// Les rapports financiers : des chiffres justes, des filtres qui filtrent
/// ce qu'ils disent filtrer, et des exports qui s'ouvrent.
library;

import 'package:atrium/core/formats.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/report_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/features/reports/export/excel_export.dart';
import 'package:atrium/features/reports/export/export_model.dart';
import 'package:atrium/features/reports/export/pdf_export.dart';
import 'package:atrium/features/reports/export/report_sections.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _bar = '01920000-0000-7000-8000-00000000e001';
const _resto = '01920000-0000-7000-8000-00000000e002';
const _awa = '01920000-0000-7000-8000-00000000e003';
const _paul = '01920000-0000-7000-8000-00000000e004';
const _sejour = '01920000-0000-7000-8000-00000000e005';
const _ardoiseChambre = '01920000-0000-7000-8000-00000000e006';
const _ardoiseBar = '01920000-0000-7000-8000-00000000e007';
const _biere = '01920000-0000-7000-8000-00000000e008';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AtriumDatabase db;
  late String typeStandard;
  final t0 = DateTime.utc(2026, 10, 1);
  var n = 0;
  String id() => '01920000-0000-7000-8000-${(0xf00000000000 + n++).toRadixString(16)}';

  Future<void> ardoise(String ident, {String? sejour}) => db
      .into(db.folios)
      .insert(
        FoliosCompanion.insert(
          id: ident,
          createdAt: t0,
          updatedAt: t0,
          hotelId: _hotel,
          number: 'FOL-${ident.substring(30)}',
          reservationRoomId: Value(sejour),
        ),
      );

  Future<void> ligne(
    String folio,
    ChargeCategory categorie,
    int montant,
    String jour, {
    String libelle = 'Ligne',
    int quantite = 1,
    String? pointDeVente,
    String? agent,
    int taxe = 0,
  }) => db
      .into(db.folioItems)
      .insert(
        FolioItemsCompanion.insert(
          id: id(),
          createdAt: t0,
          updatedAt: t0,
          folioId: folio,
          category: categorie,
          label: libelle,
          quantity: Value(quantite),
          amount: Value(montant),
          taxAmount: Value(taxe),
          businessDate: jour,
          sourceTable: Value(pointDeVente == null ? null : 'outlets'),
          sourceId: Value(pointDeVente),
          postedBy: Value(agent),
        ),
      );

  Future<void> paiement(
    String? folio,
    PaymentMethod moyen,
    int montant,
    String jour, {
    String? agent,
    bool remboursement = false,
  }) => db
      .into(db.payments)
      .insert(
        PaymentsCompanion.insert(
          id: id(),
          createdAt: t0,
          updatedAt: t0,
          hotelId: _hotel,
          method: moyen,
          amount: montant,
          folioId: Value(folio),
          receivedBy: Value(agent),
          businessDate: Value(jour),
          isRefund: Value(remboursement),
        ),
      );

  setUp(() async {
    db = AtriumDatabase.memory();
    // Les lignes sont posees a la main, sans dossier ni client parents :
    // seuls les chiffres comptent ici.
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await seedDemoData(db);
    typeStandard = roomTypeSeeds.first.id;
    n = 0;

    for (final (ident, code, libelle) in [
      (_bar, 'BAR', 'Bar'),
      (_resto, 'RESTO', 'Restaurant'),
    ]) {
      await db
          .into(db.outlets)
          .insert(
            OutletsCompanion.insert(
              id: ident,
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              code: code,
              label: libelle,
            ),
          );
    }
    for (final (ident, prenom) in [(_awa, 'Awa'), (_paul, 'Paul')]) {
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: ident,
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              employeeCode: prenom.toUpperCase(),
              firstName: prenom,
              lastName: 'Test',
            ),
          );
    }

    // Un sejour standard de deux nuits, 1er et 2 octobre.
    await db
        .into(db.reservationRooms)
        .insert(
          ReservationRoomsCompanion.insert(
            id: _sejour,
            createdAt: t0,
            updatedAt: t0,
            reservationId: id(),
            roomTypeId: typeStandard,
            arrivalDate: '2026-10-01',
            departureDate: '2026-10-03',
            status: const Value(ReservationStatus.CHECKED_OUT),
          ),
        );
    await ardoise(_ardoiseChambre, sejour: _sejour);
    await ligne(_ardoiseChambre, ChargeCategory.ROOM, 25000, '2026-10-01',
        agent: _awa, taxe: 2000);
    await ligne(_ardoiseChambre, ChargeCategory.ROOM, 25000, '2026-10-02',
        agent: _awa, taxe: 2000);
    await ligne(_ardoiseChambre, ChargeCategory.DISCOUNT, -5000, '2026-10-02',
        agent: _awa);
    // Un acompte n'est pas une vente.
    await ligne(_ardoiseChambre, ChargeCategory.DEPOSIT, 10000, '2026-10-01');
    await paiement(_ardoiseChambre, PaymentMethod.CARD, 45000, '2026-10-02',
        agent: _awa);

    // Le bar : deux bieres, payees en mobile money par Paul.
    await ardoise(_ardoiseBar);
    await ligne(_ardoiseBar, ChargeCategory.FNB, 3000, '2026-10-02',
        libelle: 'Bière', quantite: 2, pointDeVente: _bar, agent: _paul);
    await paiement(_ardoiseBar, PaymentMethod.MOBILE_MONEY, 3000, '2026-10-02',
        agent: _paul);
    await paiement(null, PaymentMethod.CASH, 1000, '2026-10-02',
        agent: _paul, remboursement: true);

    // La biere est reliee a un produit achete 600 FCFA.
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: _biere,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            reference: 'BIE',
            label: 'Bière 65 cl',
            purchasePrice: const Value(600),
            salePrice: const Value(1500),
            minStock: const Value(24),
          ),
        );
    final categorie = id();
    await db
        .into(db.menuCategories)
        .insert(
          MenuCategoriesCompanion.insert(
            id: categorie,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            label: 'Boissons',
            outletId: const Value(_bar),
          ),
        );
    await db
        .into(db.menuItems)
        .insert(
          MenuItemsCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            code: 'BIE',
            label: 'Bière',
            menuCategoryId: categorie,
            price: const Value(1500),
            productId: const Value(_biere),
          ),
        );
  });

  tearDown(() => db.close());

  FiltresRapport octobre({
    String? pointDeVente,
    String? agent,
    PaymentMethod? moyen,
    String? type,
  }) => FiltresRapport(
    du: DateTime(2026, 10, 1),
    au: DateTime(2026, 10, 3),
    pointDeVenteId: pointDeVente,
    agentId: agent,
    moyen: moyen,
    typeChambreId: type,
  );

  test("le chiffre d'affaires deduit les remises et ignore les acomptes",
      () async {
    final r = await db.chargerRapport(octobre());
    expect(r.cles.chiffreAffaires, 25000 + 25000 - 5000 + 3000);
    expect(r.remises, 5000);
    expect(r.taxes, 4000);
    expect(r.parCategorie.map((p) => p.cle), isNot(contains('DEPOSIT')));
    expect(r.parJour.map((j) => j.chiffreAffaires), [25000, 23000, 0]);
  });

  test('les encaissements se rangent par moyen et par agent, nets', () async {
    final r = await db.chargerRapport(octobre());
    expect(r.cles.encaisse, 45000 + 3000 - 1000);
    expect(r.rembourse, 1000);
    expect({for (final p in r.parMoyen) p.cle: p.montant}, {
      'CARD': 45000,
      'MOBILE_MONEY': 3000,
      'CASH': -1000,
    });
    expect(r.parAgent.first.libelle, 'Awa Test');
  });

  test('chaque filtre ne retient que ce qu il nomme', () async {
    final bar = await db.chargerRapport(octobre(pointDeVente: _bar));
    expect(bar.cles.chiffreAffaires, 3000);
    expect(bar.cles.encaisse, 3000);
    expect(bar.pointsDeVente.single.libelle, 'Bar');

    final paul = await db.chargerRapport(octobre(agent: _paul));
    expect(paul.cles.chiffreAffaires, 3000);
    expect(paul.cles.encaisse, 2000);

    final carte = await db.chargerRapport(octobre(moyen: PaymentMethod.CARD));
    expect(carte.cles.encaisse, 45000);
    // Le moyen de paiement ne filtre pas les ventes.
    expect(carte.cles.chiffreAffaires, 48000);

    final standard = await db.chargerRapport(octobre(type: typeStandard));
    expect(standard.cles.chiffreAffaires, 45000);
    expect(standard.parType.single.nuitees, 2);
  });

  test('l occupation compte les nuits vendues sur le parc', () async {
    final r = await db.chargerRapport(octobre());
    final parc = roomSeeds.length;
    expect(r.chambres, parc);
    expect(r.occupation.map((o) => o.occupees), [1, 1, 0]);
    expect(r.cles.nuitees, 2);
    expect(r.cles.nuiteesDisponibles, 3 * parc);
    expect(r.cles.prixMoyen, 25000);
  });

  test('la marge part du prix d achat du produit relie', () async {
    final r = await db.chargerRapport(octobre());
    final biere = r.marges.single;
    expect(biere.quantite, 2);
    expect(biere.cout, 1200);
    expect(biere.marge, 1800);
    expect(biere.tauxBp, 6000);
    expect(r.stock.single.sousLeSeuil, isTrue);
  });

  test('activite, caisses, menage et maintenance', () async {
    for (final (statut, arrivee) in [
      (ReservationStatus.NO_SHOW, '2026-10-02'),
      (ReservationStatus.CANCELLED, '2026-10-02'),
    ]) {
      await db
          .into(db.reservationRooms)
          .insert(
            ReservationRoomsCompanion.insert(
              id: id(),
              createdAt: t0,
              updatedAt: t0,
              reservationId: id(),
              roomTypeId: typeStandard,
              arrivalDate: arrivee,
              departureDate: '2026-10-04',
              status: Value(statut),
            ),
          );
    }
    await db
        .into(db.cashSessions)
        .insert(
          CashSessionsCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            userId: _paul,
            openedAt: Value(DateTime(2026, 10, 2, 8)),
            closedAt: Value(DateTime(2026, 10, 2, 20)),
            expectedAmount: const Value(12000),
            countedAmount: const Value(11500),
            variance: const Value(-500),
            status: const Value(CashSessionStatus.CLOSED),
          ),
        );
    final chambre = (await db.select(db.rooms).get()).first.id;
    for (final (statut, minutes) in [
      (TaskStatus.DONE, 30),
      (TaskStatus.PENDING, null),
    ]) {
      await db
          .into(db.housekeepingTasks)
          .insert(
            HousekeepingTasksCompanion.insert(
              id: id(),
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              roomId: chambre,
              type: HousekeepingTaskType.DEPARTURE,
              businessDate: '2026-10-02',
              status: Value(statut),
              assignedTo: const Value(_awa),
              durationMinutes: Value(minutes),
            ),
          );
    }
    await db
        .into(db.maintenanceTickets)
        .insert(
          MaintenanceTicketsCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            number: 'T-1',
            title: 'Fuite',
            category: const Value('Plomberie'),
            priority: const Value(Priority.URGENT),
            status: const Value(TicketStatus.RESOLVED),
            reportedAt: Value(DateTime(2026, 10, 2, 9)),
            resolvedAt: Value(DateTime(2026, 10, 2, 12)),
            cost: const Value(15000),
          ),
        );

    final r = await db.chargerRapport(octobre());
    final a = r.activite;
    expect(a.arriveesPrevues, 2, reason: 'l annulation ne compte pas');
    expect(a.arrivees, 1);
    expect(a.nonPresentes, 1);
    expect(a.departs, 1);
    expect(a.dureeMoyenneDixiemes, 20);

    final g = r.gestion;
    expect(g.caisses.single.agent, 'Paul Test');
    expect(r.ecartCaisse, -500);
    expect(g.tachesFaites, 1);
    expect(g.tachesEnAttente, 1);
    expect(g.dureeMoyenneMenage, 30);
    expect(g.ticketsSignales, 1);
    expect(g.ticketsUrgents, 1);
    expect(g.coutMaintenance, 15000);
    expect(g.delaiResolutionDixiemesHeure, 30);
    expect(g.maintenanceParCategorie.single.categorie, 'Plomberie');

    // L'agent filtre la caisse et le menage.
    final awa = await db.chargerRapport(octobre(agent: _awa));
    expect(awa.gestion.caisses, isEmpty);
    expect(awa.gestion.tachesFaites, 1);
  });

  test('les exports PDF et Excel se fabriquent, en francais', () async {
    final r = await db.chargerRapport(octobre());
    final doc = DocumentRapport(
      titre: 'Rapport financier',
      hotel: 'Edge Hotel',
      periode: 'Du 1 au 3 octobre 2026',
      filtres: const [],
      etabliLe: DateTime(2026, 10, 9, 14, 30),
      sections: SectionsRapport(r).toutes,
    );
    final xlsx = construireExcel(doc);
    expect(String.fromCharCodes(xlsx.take(2)), 'PK');
    final pdf = await construirePdf(doc);
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    expect(
      doc.nomFichier('2026-10-01', '2026-10-03'),
      'rapport-financier_2026-10-01_2026-10-03',
    );
    expect(formaterValeur(1850, Unite.pointsDeBase), '18,5 %');
    expect(formaterValeur(125000, Unite.montant), formatAmount(125000));
  });
}
