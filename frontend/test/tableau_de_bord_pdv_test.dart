/// Les chiffres du tableau de bord des points de vente.
///
/// Un seul calcul pour tous les points de vente : il prend la liste a
/// couvrir et ne connait aucun d'eux par son nom. Ce qui compte : le bar ne
/// voit que le bar, une vente est un client servi (pas une ligne), et la
/// semaine se compare a la semaine precedente arretee au meme jour.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/outlet_dashboard_queries.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _bar = '01920000-0000-7000-8000-00000000d001';
const _resto = '01920000-0000-7000-8000-00000000d002';
const _spa = '01920000-0000-7000-8000-00000000d003';
const _barman = '01920000-0000-7000-8000-00000000d004';
const _admin = '01920000-0000-7000-8000-00000000d005';

// Un jeudi.
final _jeudi = DateTime(2026, 10, 15);

void main() {
  late AtriumDatabase db;
  var compteur = 0;
  final t0 = DateTime.utc(2026, 10, 1);

  String ident() =>
      '01920000-0000-7000-8000-${(++compteur).toString().padLeft(12, '0')}';

  setUp(() async {
    db = AtriumDatabase.memory();
    compteur = 0;
    for (final (id, code, kind) in [
      (_bar, 'BAR', OutletKind.OUTLET),
      (_resto, 'REST', OutletKind.OUTLET),
      (_spa, 'SPA', OutletKind.SERVICE),
    ]) {
      await db
          .into(db.outlets)
          .insert(
            OutletsCompanion.insert(
              id: id,
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              code: code,
              label: code,
              kind: Value(kind),
            ),
          );
    }
  });
  tearDown(() => db.close());

  Future<String> ardoise(FolioType type) async {
    final id = ident();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: id,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            number: 'FOL-$compteur',
            type: Value(type),
            // Une vente de passage payee a son ardoise close ; une ardoise
            // de comptoir encore ouverte est « a payer ».
            status: Value(
              type == FolioType.WALK_IN ? FolioStatus.CLOSED : FolioStatus.OPEN,
            ),
          ),
        );
    return id;
  }

  Future<void> vendre(
    String folio,
    String pointDeVente,
    DateTime jour, {
    String label = 'Biere',
    int prix = 1500,
    int quantite = 1,
    int heure = 20,
    bool annulee = false,
  }) async {
    await db
        .into(db.folioItems)
        .insert(
          FolioItemsCompanion.insert(
            id: ident(),
            createdAt: t0,
            updatedAt: t0,
            folioId: folio,
            category: ChargeCategory.FNB,
            label: label,
            quantity: Value(quantite),
            unitPrice: Value(prix),
            amount: Value(prix * quantite),
            businessDate:
                '${jour.year}-${jour.month.toString().padLeft(2, '0')}-'
                '${jour.day.toString().padLeft(2, '0')}',
            isVoid: Value(annulee),
            sourceTable: const Value('outlets'),
            sourceId: Value(pointDeVente),
            postedAt: Value(DateTime(jour.year, jour.month, jour.day, heure)),
          ),
        );
  }

  FiltresPdv filtres(List<String> points, PeriodePdv periode) =>
      FiltresPdv(pointsDeVente: points, periode: periode, reference: _jeudi);

  group('les periodes', () {
    test('la semaine court du lundi au jour regarde', () {
      final f = filtres([_bar], PeriodePdv.semaine);
      expect(f.du, DateTime(2026, 10, 12));
      expect(f.au, _jeudi);
      expect(f.precedente.du, DateTime(2026, 10, 5));
      expect(f.precedente.au, DateTime(2026, 10, 8));
    });

    test('le mois se compare au mois precedent arrete au meme jour', () {
      final f = FiltresPdv(
        pointsDeVente: const [_bar],
        periode: PeriodePdv.mois,
        reference: DateTime(2026, 3, 31),
      );
      expect(f.du, DateTime(2026, 3, 1));
      expect(f.precedente.du, DateTime(2026, 2, 1));
      // Fevrier n'a pas de 31.
      expect(f.precedente.au, DateTime(2026, 2, 28));
    });

    test('janvier se compare a decembre', () {
      final f = FiltresPdv(
        pointsDeVente: const [_bar],
        periode: PeriodePdv.mois,
        reference: DateTime(2027, 1, 10),
      );
      expect(f.precedente.du, DateTime(2026, 12, 1));
      expect(f.precedente.au, DateTime(2026, 12, 10));
    });
  });

  group('les chiffres', () {
    test('le bar ne voit que le bar', () async {
      final passage = await ardoise(FolioType.WALK_IN);
      await vendre(passage, _bar, _jeudi, prix: 2000);
      final autre = await ardoise(FolioType.WALK_IN);
      await vendre(autre, _resto, _jeudi, prix: 9000);

      final c = await db.chiffresPdv(filtres([_bar], PeriodePdv.jour));

      expect(c.recette, 2000);
      expect(c.ventes, 1);
    });

    test('trois bieres en 101 dans la soiree font une vente', () async {
      final chambre = await ardoise(FolioType.GUEST);
      for (var i = 0; i < 3; i++) {
        await vendre(chambre, _bar, _jeudi, heure: 19 + i);
      }
      final passage = await ardoise(FolioType.WALK_IN);
      await vendre(passage, _bar, _jeudi, prix: 1000, quantite: 2);

      final c = await db.chiffresPdv(filtres([_bar], PeriodePdv.jour));

      expect(c.ventes, 2);
      expect(c.articles, 5);
      expect(c.recette, 4500 + 2000);
      expect(c.surPlace, 2000);
      expect(c.enChambre, 4500);
      expect(c.ticketMoyen, 3250);
    });

    test("une ligne annulee n'est pas une vente", () async {
      final passage = await ardoise(FolioType.WALK_IN);
      await vendre(passage, _bar, _jeudi, annulee: true);

      final c = await db.chiffresPdv(filtres([_bar], PeriodePdv.jour));

      expect(c.recette, 0);
      expect(c.ventes, 0);
      expect(c.ticketMoyen, 0);
    });

    test('sans point de vente, rien -- pas tout', () async {
      final passage = await ardoise(FolioType.WALK_IN);
      await vendre(passage, _bar, _jeudi);

      final c = await db.chiffresPdv(filtres(const [], PeriodePdv.jour));

      expect(c.recette, 0);
    });

    test('la semaine se compare a la precedente', () async {
      final f = await ardoise(FolioType.WALK_IN);
      await vendre(f, _bar, DateTime(2026, 10, 12), prix: 5000); // lundi
      await vendre(f, _bar, DateTime(2026, 10, 6), prix: 3000); // mardi d'avant
      await vendre(f, _bar, DateTime(2026, 10, 10), prix: 7000); // samedi d'avant

      final t = await db.chargerTableauDeBordPdv(
        filtres([_bar], PeriodePdv.semaine),
      );

      expect(t.chiffres.recette, 5000);
      // Le samedi d'avant est apres le jeudi : hors de la comparaison.
      expect(t.precedent.recette, 3000);
    });
  });

  test("une ardoise du comptoir encore ouverte est a payer, pas payee", () async {
    final ouverte = await ardoise(FolioType.WALK_IN);
    await db.customStatement(
      "UPDATE folios SET status = 'OPEN' WHERE id = '$ouverte'",
    );
    await vendre(ouverte, _bar, _jeudi, prix: 3000);
    final payee = await ardoise(FolioType.WALK_IN);
    await db.customStatement(
      "UPDATE folios SET status = 'CLOSED' WHERE id = '$payee'",
    );
    await vendre(payee, _bar, _jeudi, prix: 1000);

    final c = await db.chiffresPdv(filtres([_bar], PeriodePdv.jour));

    expect(c.recette, 4000);
    expect(c.aPayer, 3000);
    expect(c.surPlace, 1000);
    expect(c.enChambre, 0);
  });

  group('meilleures ventes et heures de pointe', () {
    test("les articles qui rapportent le plus d'abord", () async {
      final f = await ardoise(FolioType.WALK_IN);
      await vendre(f, _bar, _jeudi, label: 'Biere', prix: 1500, quantite: 4);
      await vendre(f, _bar, _jeudi, label: 'Whisky', prix: 8000);
      await vendre(f, _bar, _jeudi, label: 'Soda', prix: 500, quantite: 2);

      final t = await db.chargerTableauDeBordPdv(
        filtres([_bar], PeriodePdv.jour),
      );

      expect(t.meilleuresVentes.map((l) => l.libelle), [
        'Whisky',
        'Biere',
        'Soda',
      ]);
      expect(t.meilleuresVentes[1].quantite, 4);
    });

    test("l'heure de pointe se lit sur l'heure de la saisie", () async {
      final f = await ardoise(FolioType.WALK_IN);
      await vendre(f, _bar, _jeudi, heure: 13, prix: 2000);
      await vendre(f, _bar, _jeudi, heure: 21, prix: 1500, quantite: 3);

      final t = await db.chargerTableauDeBordPdv(
        filtres([_bar], PeriodePdv.jour),
      );

      expect(t.parHeure, hasLength(24));
      expect(t.parHeure[13].montant, 2000);
      expect(t.parHeure[21].articles, 3);
      expect(t.heureDePointe?.heure, 21);
    });
  });

  group('le perimetre', () {
    Future<void> agent(String id) => db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: id,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            employeeCode: id.substring(30),
            firstName: 'Agent',
            lastName: id.substring(30),
          ),
        );

    test('le barman rattache ne voit que le bar', () async {
      await agent(_barman);
      await db
          .into(db.userOutlets)
          .insert(UserOutletsCompanion.insert(userId: _barman, outletId: _bar));

      final p = await OrderRepository(db).watchPerimetre(_barman).first;

      expect(p.rattache, isTrue);
      expect(p.pointsDeVente.map((o) => o.id), [_bar]);
      expect(p.plusieurs, isFalse);
    });

    test("sans rattachement, tout l'hotel, rangé par genre", () async {
      await agent(_admin);

      final p = await OrderRepository(db).watchPerimetre(_admin).first;

      expect(p.rattache, isFalse);
      expect(p.pointsDeVente, hasLength(3));
      expect(p.duGenre(OutletKind.SERVICE).map((o) => o.id), [_spa]);
      expect(p.duGenre(OutletKind.OUTLET), hasLength(2));
    });
  });

  group('le comparatif', () {
    test('le plus gros d abord, le point de vente muet compris', () async {
      final f = await ardoise(FolioType.WALK_IN);
      await vendre(f, _resto, _jeudi, prix: 9000);
      await vendre(f, _bar, _jeudi, prix: 3000);
      await vendre(f, _bar, _jeudi.subtract(const Duration(days: 1)), prix: 2000);

      final lignes = await db
          .watchComparatifPdv(filtres([_bar, _resto, _spa], PeriodePdv.jour))
          .first;

      expect(lignes.map((l) => l.pointDeVente), [_resto, _bar, _spa]);
      expect(lignes[1].chiffres.recette, 3000);
      // Hier, pour la variation.
      expect(lignes[1].precedent.recette, 2000);
      expect(lignes[2].chiffres.recette, 0);
    });
  });

  group('les tiroirs', () {
    Future<void> caisse(
      String pointDeVente, {
      bool ouverte = false,
      DateTime? fermee,
      DateTime? recue,
    }) async {
      await db
          .into(db.users)
          .insertOnConflictUpdate(
            UsersCompanion.insert(
              id: _barman,
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              employeeCode: 'BARMAN',
              firstName: 'Paul',
              lastName: 'Bar',
            ),
          );
      await db
          .into(db.cashSessions)
          .insert(
            CashSessionsCompanion.insert(
              id: ident(),
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              userId: _barman,
              outletId: Value(pointDeVente),
              status: Value(
                ouverte ? CashSessionStatus.OPEN : CashSessionStatus.CLOSED,
              ),
              openingFloat: const Value(5000),
              expectedAmount: const Value(12000),
              closedAt: Value(fermee),
              countedAmount: Value(ouverte ? null : 11500),
              receivedAt: Value(recue),
              receivedAmount: Value(recue == null ? null : 11500),
            ),
          );
    }

    test('ouverts, en attente, ou fermes sur la periode -- pas avant', () async {
      final midi = DateTime(2026, 10, 15, 12).toUtc();
      await caisse(_bar, ouverte: true);
      // Versee il y a un mois, jamais confirmee : de l'argent en attente.
      await caisse(_bar, fermee: DateTime(2026, 9, 10, 23).toUtc());
      // Versee et recue aujourd'hui.
      await caisse(_bar, fermee: midi, recue: midi);
      // Versee et recue la semaine derniere : de l'histoire.
      final avant = DateTime(2026, 10, 8, 23).toUtc();
      await caisse(_bar, fermee: avant, recue: avant);
      // Le restaurant n'est pas regarde.
      await caisse(_resto, ouverte: true);

      final tiroirs = await db
          .watchTiroirsPdv(filtres([_bar], PeriodePdv.jour))
          .first;

      expect(tiroirs, hasLength(3));
      expect(tiroirs.first.ouvert, isTrue);
      expect(tiroirs.first.agent, 'Paul Bar');
      expect(tiroirs.where((t) => t.enAttente), hasLength(1));
      expect(tiroirs.where((t) => t.recu == 11500), hasLength(1));
    });
  });

  group('le stock', () {
    Future<void> magasin(String id, String? pointDeVente) => db
        .into(db.stockLocations)
        .insert(
          StockLocationsCompanion.insert(
            id: id,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            code: id.substring(30),
            label: pointDeVente == null ? 'Économat' : 'Stock $pointDeVente',
            outletId: Value(pointDeVente),
            isCentral: Value(pointDeVente == null),
          ),
        );

    test('ce qui manque au bar, et ses ravitaillements en attente', () async {
      const economat = '01920000-0000-7000-8000-00000000e001';
      const stockBar = '01920000-0000-7000-8000-00000000e002';
      const stockResto = '01920000-0000-7000-8000-00000000e003';
      await magasin(economat, null);
      await magasin(stockBar, _bar);
      await magasin(stockResto, _resto);
      final produits = <String, String>{};
      for (final nom in ['Biere', 'Soda', 'Vin']) {
        produits[nom] = ident();
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: produits[nom]!,
                createdAt: t0,
                updatedAt: t0,
                hotelId: _hotel,
                reference: nom.toUpperCase(),
                label: nom,
                minStock: const Value(6),
              ),
            );
      }
      Future<void> niveau(String produit, String lieu, int n) => db
          .into(db.stockLevels)
          .insert(
            StockLevelsCompanion.insert(
              id: ident(),
              createdAt: t0,
              updatedAt: t0,
              productId: produits[produit]!,
              stockLocationId: lieu,
              quantity: Value(n),
            ),
          );
      await niveau('Biere', stockBar, 2); // sous le seuil
      await niveau('Soda', stockBar, -1); // negatif
      await niveau('Vin', stockBar, 12); // assez
      await niveau('Vin', stockResto, 0); // pas le bar
      await db
          .into(db.stockMovements)
          .insert(
            StockMovementsCompanion.insert(
              id: ident(),
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              productId: produits['Biere']!,
              stockLocationId: economat,
              counterpartLocationId: const Value(stockBar),
              type: StockMovementType.TRANSFER,
              quantity: 24,
              status: const Value(StockMovementStatus.PENDING),
            ),
          );

      final stock = await db
          .watchStockPdv(filtres([_bar], PeriodePdv.jour))
          .first;

      // Le plus en manque d'abord : le negatif.
      expect(stock.bas.map((s) => s.produit), ['Soda', 'Biere']);
      expect(stock.transferts.single.quantite, 24);
      expect(stock.transferts.single.vers, 'Stock $_bar');
    });
  });
}
